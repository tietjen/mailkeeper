import AppKit
import Foundation
import Network
import Security
import SQLite3
import Sparkle

// Sandboxed probe app. Modes:
//   --auto         run the sandbox/keychain/network/ATS checks, print key=value lines, quit
//   --update-test  check the local feed and install the update without UI (custom user driver)
//   (no args)      if this is version 2, report that the update relaunched it, then quit
// Results also go to the spike's local HTTP server as GET /report?... (its access log is the
// channel out of the sandbox — reading the app container from outside triggers a TCC prompt).

setvbuf(stdout, nil, _IOLBF, 0)
let appVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
let args = CommandLine.arguments
let realHome = String(cString: getpwuid(getuid())!.pointee.pw_dir)

func report(_ key: String, _ value: String) {
    print("\(key)=\(value)")
    var c = URLComponents(string: "http://127.0.0.1:8765/report")!
    c.queryItems = [URLQueryItem(name: "v", value: appVersion), URLQueryItem(name: key, value: value)]
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: c.url!) { _, _, _ in sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + 2)
}

// MARK: - Checks

func checkSandboxAndStorage() {
    report("sandbox", ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ? "yes" : "no")
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "S4Spike")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    report("appSupport", dir.path.replacingOccurrences(of: realHome, with: "~"))

    var db: OpaquePointer?
    let path = dir.appending(path: "probe.sqlite").path
    guard sqlite3_open(path, &db) == SQLITE_OK else { report("sqlite", "open failed"); return }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "CREATE VIRTUAL TABLE IF NOT EXISTS t USING fts5(body, tokenize='unicode61 remove_diacritics 2'); INSERT INTO t VALUES('Grüße aus der Sandbox');", nil, nil, nil)
    func count(_ q: String) -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM t WHERE t MATCH ?1", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, q, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }
    // unicode61 remove_diacritics folds ü→u, but ß is a letter, not a diacritic.
    report("sqliteFTS5", "version=\(String(cString: sqlite3_libversion())) gruße=\(count("gruße")) GRÜSSE=\(count("GRÜSSE")) grusse=\(count("grusse"))")

    for p in ["~/.config/mailkeeper/test-accounts.json", "~/Projects/gitea/mailkeeper/README.md", "~/Documents"] {
        let full = p.replacingOccurrences(of: "~", with: realHome)
        let readable = (try? Data(contentsOf: URL(fileURLWithPath: full))) != nil
            || ((try? FileManager.default.contentsOfDirectory(atPath: full)) != nil)
        report("read \(p)", readable ? "ALLOWED" : "denied")
    }
}

func checkKeychain() {
    let service = "de.paranoidsecurity.MailKeeper.S4Spike"
    for dataProtection in [false, true] {
        var base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "probe"]
        if dataProtection { base[kSecUseDataProtectionKeychain as String] = true }
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data("not-a-secret".utf8)
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        var query = base
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &out)
        let roundTrip = (out as? Data).map { String(decoding: $0, as: UTF8.self) == "not-a-secret" } ?? false
        let delStatus = SecItemDelete(base as CFDictionary)
        report(dataProtection ? "keychain dataProtection" : "keychain fileBased",
               "add=\(addStatus) read=\(readStatus) roundTrip=\(roundTrip) delete=\(delStatus)")
    }
    // Reading an item another program created (e.g. via /usr/bin/security) shows a keychain
    // access prompt even with kSecUseAuthenticationUIFail — seen in the first run, so not
    // probed again: the app must create and own its credential items.
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

func greeting(host: String, port: UInt16, tls: Bool) async -> String {
    await withCheckedContinuation { cont in
        let once = Once()
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: tls ? .tls : .tcp)
        let finish = { (s: String) in if once.claim() { conn.cancel(); cont.resume(returning: s) } }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.receive(minimumIncompleteLength: 1, maximumLength: 120) { data, _, _, err in
                    let line = data.map { String(decoding: $0, as: UTF8.self).components(separatedBy: "\r\n")[0] } ?? "no data \(String(describing: err))"
                    finish("ok: " + String(line.prefix(60)))
                }
            case .failed(let e): finish("failed: \(e)")
            case .waiting(let e): finish("waiting: \(e)")
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { finish("timeout") }
    }
}

func http(_ url: String) async -> String {
    var req = URLRequest(url: URL(string: url)!)
    req.timeoutInterval = 10
    do {
        let (_, r) = try await URLSession.shared.data(for: req)
        return "HTTP \((r as? HTTPURLResponse)?.statusCode ?? -1)"
    } catch {
        let e = error as NSError
        return "error \(e.code)"
    }
}

func checkNetwork() async {
    report("imaps mail.parasec.de:993", await greeting(host: "mail.parasec.de", port: 993, tls: true))
    report("tcp 127.0.0.1:1143 (Bridge)", await greeting(host: "127.0.0.1", port: 1143, tls: false))
    report("https apple.com", await http("https://www.apple.com/library/test/success.html"))
    report("http litellm.rk1.ziti:4000", await http("http://litellm.rk1.ziti:4000/health/liveliness"))
    report("http 127.0.0.1:8765", await http("http://127.0.0.1:8765/ping"))
    report("http localhost:8765", await http("http://localhost:8765/ping"))
}

// MARK: - Sparkle without UI

final class AutoInstallDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { report("update", "checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        report("update", "found \(appcastItem.versionString)")
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        report("update", "notFound \((error as NSError).code)")
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let e = error as NSError
        report("update", "error \(e.code) \(e.localizedDescription.prefix(120))")
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { report("update", "downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { report("update", "extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        report("update", "readyToInstall")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        report("update", "installing terminated=\(applicationTerminated)")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        report("update", "installed relaunched=\(relaunched)")
        acknowledgement()
    }
    func dismissUpdateInstallation() {}
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var updater: SPUUpdater?
    let driver = AutoInstallDriver()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if args.contains("--auto") {
            Task {
                report("version", appVersion)
                checkSandboxAndStorage()
                checkKeychain()
                await checkNetwork()
                report("done", "auto")
                exit(0)
            }
        } else if args.contains("--update-test") {
            report("update", "v\(appVersion) started at \(Bundle.main.bundlePath.replacingOccurrences(of: realHome, with: "~"))")
            let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
            do {
                try u.start()
                updater = u
                u.checkForUpdates()
            } catch {
                report("update", "start failed: \(error)")
                exit(1)
            }
        } else {
            report("launched", "v\(appVersion) at \(Bundle.main.bundlePath.replacingOccurrences(of: realHome, with: "~")) sandbox=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

#if canImport(Glibc)
// Before Foundation: Glibc's `stdout` is a mutable global that Swift 6 refuses otherwise.
@preconcurrency import Glibc
#endif
import Foundation
import MailKeeperKit
import MailKeeperServer

// mailkeeperd — fetches the configured mailboxes into one archive per person, over and over
// (mailkeeper-server). It only reads from mail servers. SIGTERM ends it at once: every write to
// an archive is complete or absent (ADR-0001), the same as Ctrl-C for `mkctl sync`.

setvbuf(stdout, nil, _IOLBF, 0)
// PID 1 in a container ignores SIGTERM without a handler, and Kubernetes would wait for SIGKILL.
_ = signal(SIGTERM) { _ in _exit(0) }
_ = signal(SIGINT) { _ in _exit(0) }

let usage = """
usage: mailkeeperd [--config <file>] [--once | --check-config | --secret-names]

  --config <file>   the configuration (default /etc/mailkeeper/config.json)
  --once            one run over all accounts, then exit (1 if any account or export failed)
  --check-config    read and check the configuration, then exit
  --secret-names    the secret file name each account reads its password from

"""

var args = Array(CommandLine.arguments.dropFirst())
var configPath = "/etc/mailkeeper/config.json"
if let i = args.firstIndex(of: "--config") {
    guard i + 1 < args.count else { FileHandle.standardError.write(Data(usage.utf8)); exit(2) }
    configPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let modes: Set<String> = ["--once", "--check-config", "--secret-names"]
guard args.allSatisfy(modes.contains), args.count <= 1 else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

let config: ServerConfig
do {
    config = try ServerConfig.load(from: URL(fileURLWithPath: configPath))
} catch {
    FileHandle.standardError.write(Data("mailkeeperd: \(configPath): \(error)\n".utf8))
    exit(2)
}
let accountCount = config.people.reduce(0) { $0 + $1.accounts.count }
let exportNote = config.paperless.map { p in
    ", Paperless \(p.mode.rawValue) für " + config.people.filter { $0.paperless != nil }.map(\.id).joined(separator: ", ")
} ?? ""

switch args.first {
case "--check-config":
    print("Konfiguration in Ordnung: \(config.people.count) Personen, \(accountCount) Konten\(exportNote)")
case "--secret-names":
    for person in config.people {
        for spec in person.accounts {
            let account = try spec.accountConfig()
            print("\(person.id)/\(spec.id): \(FileSecretBackend.fileName(for: CredentialStore.key(for: account)))")
        }
    }
default:
    let once = args.first == "--once"
    let daemon = Daemon(config: config) { print($0) }
    print("mailkeeperd: \(config.people.count) Personen, \(accountCount) Konten\(exportNote)"
          + (once ? ", ein Lauf" : ", alle \(config.intervalSeconds) s"))
    repeat {
        let clean = await daemon.runOnce()
        if once { exit(clean ? 0 : 1) }  // a smoke test or a job sees whether every account got through
        try? await Task.sleep(for: .seconds(config.intervalSeconds))
    } while true
}

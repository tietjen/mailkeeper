import Foundation
import NIOCore
import NIOIMAP

// Usage: S1IMAP <account-id> [--out report.json]
// Reads ~/.config/mailkeeper/test-accounts.json; password from the login keychain.
// Writes only to the account's allowed mailboxes (hard allowlist, see guardAllowed).

setvbuf(stdout, nil, _IOLBF, 0)

struct AccountConfig: Decodable {
    struct Keychain: Decodable { let service: String; let account: String }
    let id: String, kind: String, host: String, port: Int, security: String, username: String
    let keychain: Keychain
    let allowedMailboxes: [String]
}

struct ConfigFile: Decodable { let accounts: [AccountConfig] }

let configDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/mailkeeper")

func keychainSecret(service: String, account: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    return s.isEmpty ? nil : s
}

// MARK: - Report

final class Report {
    var fields: [String: Any] = [:]
    var steps: [[String: Any]] = []

    func step(_ name: String, _ ok: Bool, _ info: [String: Any] = [:], seconds: Double) {
        var s = info
        s["step"] = name
        s["ok"] = ok
        s["seconds"] = (seconds * 1000).rounded() / 1000
        steps.append(s)
        let detail = info.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        print(String(format: "%@ %-26@ %6.3fs  %@", ok ? "ok " : "XX ", name, seconds, String(detail.prefix(220))))
    }

    /// Non-generic overload for steps that only report: keeps multi-statement closures inferable.
    @discardableResult
    func timed(_ name: String, _ body: () async throws -> (Bool, [String: Any])) async -> Bool? {
        let t = Date()
        do {
            let (v, info) = try await body()
            step(name, true, info, seconds: Date().timeIntervalSince(t))
            return v
        } catch {
            step(name, false, ["error": "\(error)"], seconds: Date().timeIntervalSince(t))
            return nil
        }
    }

    func timed<T>(_ name: String, _ body: () async throws -> (T, [String: Any])) async -> T? {
        let t = Date()
        do {
            let (v, info) = try await body()
            step(name, true, info, seconds: Date().timeIntervalSince(t))
            return v
        } catch {
            step(name, false, ["error": "\(error)"], seconds: Date().timeIntervalSince(t))
            return nil
        }
    }
}

// MARK: - Helpers

func guardAllowed(_ mailbox: String, _ a: AccountConfig) throws {
    guard a.allowedMailboxes.contains("*") || a.allowedMailboxes.contains(mailbox) else {
        throw IMAPError("mailbox \(mailbox) is not in the allowlist for \(a.id) — refusing")
    }
}

func uidSet(_ uids: [UInt32]) -> LastCommandSet<UID> {
    let set = uids.dropFirst().reduce(MessageIdentifierSet<UID>(UID(rawValue: uids[0]))) {
        $0.union(MessageIdentifierSet<UID>(UID(rawValue: $1)))
    }
    return .set(MessageIdentifierSetNonEmpty(set: set)!)
}

let allUIDs: LastCommandSet<UID> = .set(MessageIdentifierSetNonEmpty(range: MessageIdentifierRange(UID(rawValue: 1)...)))

func capabilities(_ r: CommandResult) -> [String] {
    r.untagged.flatMap { p -> [String] in
        if case .capabilityData(let caps) = p { return caps.map { String($0) } }
        return []
    }
}

func searchUIDs(_ r: CommandResult) -> [UInt32] {
    r.untagged.flatMap { p -> [UInt32] in
        if case .mailboxData(.search(let ids, _)) = p { return ids.map { $0.rawValue } }
        return []
    }
}

func messageID(in raw: Data) -> String? {
    let head = String(decoding: raw.prefix(4096), as: UTF8.self)
    for line in head.components(separatedBy: "\r\n") {
        if line.isEmpty { break }
        if line.lowercased().hasPrefix("message-id:") {
            return line.dropFirst("message-id:".count).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

func appendedUIDs(_ r: CommandResult) -> [UInt32] {
    guard case .uidAppend(let a)? = r.code else { return [] }
    return a.uids.set.map { $0.rawValue }
}

// MARK: - Probe

func probe(_ a: AccountConfig) async -> Report {
    let rep = Report()
    rep.fields["account"] = a.id
    rep.fields["kind"] = a.kind
    rep.fields["host"] = a.host
    let isProton = a.kind == "proton-bridge", isGmail = a.kind == "gmail"
    let testMailbox = isProton ? "Folders/MailKeeper-Test" : "MailKeeper-Test"
    let labelMailbox: String? = isProton ? "Labels/MailKeeper-Label" : (isGmail ? "MailKeeper-Label" : nil)

    guard var password = keychainSecret(service: a.keychain.service, account: a.keychain.account) else {
        rep.step("keychain", false, ["error": "no keychain item \(a.keychain.service)"], seconds: 0)
        return rep
    }
    // Google shows app passwords as "abcd efgh ijkl mnop" and IMAP rejects the spaces.
    if isGmail { password.removeAll { $0 == " " } }

    guard let conn = await rep.timed("connect", {
        let c = try await IMAPConnection.connect(host: a.host, port: a.port, implicitTLS: a.security == "tls")
        let greeting = c.greeting.replacingOccurrences(of: #"\b\d{1,3}(\.\d{1,3}){3}\b"#, with: "<ip>", options: .regularExpression)
        return (c, ["tls": a.security, "greeting": String(greeting.prefix(120))])
    }) else { return rep }

    if a.security == "starttls-pinned" {
        let pinFile = configDir.appending(path: "pins.json")
        var pins = (try? JSONSerialization.jsonObject(with: Data(contentsOf: pinFile)) as? [String: String]) ?? [:]
        let key = "\(a.host):\(a.port)"
        let seen = PinBox()
        let ok: Bool? = await rep.timed("starttls+pin", {
            try await conn.startTLSPinned(expected: pins[key], seen: seen)
            let caps = try await conn.run(.capability)  // first command over TLS: fails here on pin mismatch
            guard caps.ok, let fp = seen.seen else { throw IMAPError("TLS handshake failed (pin mismatch?)") }
            let tofu = pins[key] == nil
            if tofu {
                pins[key] = fp
                try JSONSerialization.data(withJSONObject: pins, options: [.prettyPrinted, .sortedKeys]).write(to: pinFile)
            }
            return (true, ["pin": String(fp.prefix(16)) + "…", "trustOnFirstUse": tofu])
        })
        if ok == nil { await conn.close(); return rep }
    }

    let preCaps: [String] = await rep.timed("capability (pre-login)", {
        let c = capabilities(try await conn.run(.capability))
        return (c, ["count": c.count, "auth": c.filter { $0.hasPrefix("AUTH=") }.joined(separator: ",")])
    }) ?? []
    _ = preCaps

    guard await rep.timed("login", {
        let r = try await conn.run(.login(username: a.username, password: password))
        guard r.ok else { throw IMAPError("LOGIN failed: \(r.text)") }
        return (true, [:])
    }) != nil else { await conn.close(); return rep }

    let caps: [String] = await rep.timed("capability", {
        let c = capabilities(try await conn.run(.capability))
        let interesting = ["IMAP4rev2", "UIDPLUS", "MOVE", "CONDSTORE", "QRESYNC", "SPECIAL-USE", "X-GM-EXT-1",
                           "LITERAL+", "LITERAL-", "IDLE", "ESEARCH", "COMPRESS=DEFLATE", "APPENDLIMIT", "ID", "ENABLE",
                           "UTF8=ACCEPT", "OBJECTID", "STATUS=SIZE", "SORT", "THREAD=REFERENCES"]
        let has = interesting.filter { want in c.contains { $0.uppercased() == want || $0.uppercased().hasPrefix(want + "=") } }
        return (c, ["has": has.joined(separator: ","), "count": c.count])
    }) ?? []
    let hasCap = { (name: String) in caps.contains { $0.uppercased() == name || $0.uppercased().hasPrefix(name + "=") } }
    rep.fields["capabilities"] = caps

    // LIST with SPECIAL-USE attributes
    struct Box { let name: String; let attrs: [String] }
    let boxes: [Box] = await rep.timed("list", {
        let r = try await conn.run(.list(nil, reference: MailboxName(""), .mailbox(ByteBuffer(string: "*")), []))
        let boxes = r.untagged.compactMap { p -> Box? in
            if case .mailboxData(.list(let info)) = p {
                return Box(name: info.path.name.string, attrs: info.attributes.map { String($0) })
            }
            return nil
        }
        let specialNames: Set<String> = ["\\all", "\\trash", "\\sent", "\\junk", "\\drafts", "\\archive", "\\flagged", "\\important"]
        var specialUse: [String] = []
        for b in boxes {
            let attrs = b.attrs.filter { specialNames.contains($0.lowercased()) }
            if !attrs.isEmpty { specialUse.append(attrs.joined(separator: "+") + "=" + b.name) }
        }
        var info: [String: Any] = ["count": boxes.count, "specialUse": specialUse.joined(separator: " ")]
        // Real (non-test) mailboxes would leak folder names of a personal account into the report.
        if a.allowedMailboxes.contains("*") { info["names"] = boxes.map(\.name).joined(separator: " | ") }
        return (boxes, info)
    }) ?? []
    let specialUse = { (attr: String) in boxes.first { $0.attrs.contains { $0.lowercased() == attr } }?.name }

    // Test mailbox (and label mailbox) must exist; create only on dedicated test accounts.
    var writable = true
    for mb in [testMailbox] + (labelMailbox.map { [$0] } ?? []) {
        if boxes.contains(where: { $0.name == mb }) { continue }
        let created = await rep.timed("create \(mb)", {
            try guardAllowed(mb, a)
            guard a.allowedMailboxes.contains("*") else { throw IMAPError("missing — create it in the provider's web UI") }
            let r = try await conn.run(.create(MailboxName(mb), []))
            guard r.ok else { throw IMAPError(r.text) }
            return (true, [:])
        })
        if created == nil && mb == testMailbox { writable = false }
    }

    let condstore = hasCap("CONDSTORE")
    if hasCap("QRESYNC") {
        _ = await rep.timed("enable QRESYNC", {
            let r = try await conn.run(.enable([Capability("QRESYNC")]))
            return (r.ok, ["ok": r.ok])
        })
    }

    guard writable, await rep.timed("select \(testMailbox)", {
        try guardAllowed(testMailbox, a)
        let r = try await conn.run(.select(MailboxName(testMailbox), condstore ? [.basic(KeyValue(key: "CONDSTORE", value: nil))] : []))
        guard r.ok else { throw IMAPError(r.text) }
        var info: [String: Any] = ["readWrite": r.code == .readWrite]
        for p in r.untagged {
            if case .mailboxData(.exists(let n)) = p { info["exists"] = n }
            if case .conditionalState(.ok(let text)) = p, let code = text.code {
                switch code {
                case .uidValidity(let v): info["uidValidity"] = "\(v)"
                case .uidNext(let u): info["uidNext"] = u.rawValue
                case .highestModificationSequence(let m): info["highestModSeq"] = "\(m)"
                default: break
                }
            }
        }
        return (true, info)
    }) != nil else { await conn.close(); return rep }

    // APPEND fixtures (idempotent via Message-ID search) with explicit INTERNALDATE.
    for (i, f) in fixtures.enumerated() {
        _ = await rep.timed("append \(f.messageID.prefix(14))", {
            let existing = searchUIDs(try await conn.run(.uidSearch(key: .header("Message-ID", ByteBuffer(string: f.messageID)))))
            if !existing.isEmpty { return (true, ["skipped": "already present", "uids": existing]) }
            let date = ServerMessageDate(ServerMessageDate.Components(year: 2019, month: 3, day: 14 + i, hour: 10, minute: 0, second: 0, timeZoneMinutes: 60)!)
            let r = try await conn.append(to: MailboxName(testMailbox), message: f.raw, flags: f.flagged ? [.flagged] : [], date: date)
            guard r.ok else { throw IMAPError("APPEND: \(r.text)") }
            return (true, ["bytes": f.raw.count, "appendUID": appendedUIDs(r)])
        })
    }

    // FETCH everything back: byte identity, INTERNALDATE, \Seen untouched by BODY.PEEK.
    var uidByMessageID: [String: UInt32] = [:]
    _ = await rep.timed("fetch BODY.PEEK[]", {
        var attrs: [FetchAttribute] = [.uid, .flags, .internalDate, .rfc822Size, .bodySection(peek: true, .complete, nil)]
        if isGmail { attrs += [.gmailMessageID, .gmailThreadID, .gmailLabels] }
        if condstore { attrs.append(.modificationSequence) }
        let r = try await conn.run(.uidFetch(allUIDs, attrs, []), timeout: 180)
        guard r.ok else { throw IMAPError(r.text) }
        var rows: [[String: Any]] = []
        var identical = 0, seen = 0
        for m in r.fetches {
            let mid = messageID(in: m.body)
            let fixture = fixtures.first { $0.messageID == mid }
            if let mid, let uid = m.uid { uidByMessageID[mid] = uid }
            let same = fixture.map { sha256($0.raw) == sha256(m.body) } ?? false
            if same { identical += 1 }
            if m.flags.contains(where: { $0.lowercased() == "\\seen" }) { seen += 1 }
            var row: [String: Any] = ["uid": m.uid ?? 0, "messageID": mid ?? "?", "bytesIdentical": same,
                                      "size": m.size ?? -1, "bodyBytes": m.body.count,
                                      "fixtureBytes": fixture?.raw.count ?? -1,
                                      "internalDate": m.internalDate ?? "?", "flags": m.flags.joined(separator: " ")]
            if isGmail {
                row["gmMsgID"] = m.gmailMessageID.map(String.init) ?? "-"
                row["gmThrID"] = m.gmailThreadID.map(String.init) ?? "-"
                row["gmLabels"] = m.gmailLabels.joined(separator: ",")
            }
            if let ms = m.modseq { row["modseq"] = ms }
            rows.append(row)
        }
        rep.fields["messages"] = rows
        return (true, ["messages": r.fetches.count, "bytesIdentical": identical, "seenAfterPeek": seen])
    })

    // Labels: Gmail via X-GM-LABELS, Proton via COPY into Labels/<name>.
    if let label = labelMailbox, let uid1 = uidByMessageID[fixtures[0].messageID] {
        if isGmail {
            _ = await rep.timed("gmail +X-GM-LABELS", {
                let r = try await conn.run(.uidStore(uidSet([uid1]), [], .gmailLabels(.add(silent: false, gmailLabels: [GmailLabel(ByteBuffer(string: label))]))))
                guard r.ok else { throw IMAPError(r.text) }
                let f = try await conn.run(.uidFetch(uidSet([uid1]), [.uid, .gmailLabels], []))
                return (true, ["labels": f.fetches.first?.gmailLabels.joined(separator: ",") ?? "?"])
            })
        } else if isProton {
            _ = await rep.timed("proton COPY → label", {
                try guardAllowed(label, a)
                let r = try await conn.run(.uidCopy(uidSet([uid1]), MailboxName(label)))
                guard r.ok else { throw IMAPError(r.text) }
                let sel = try await conn.run(.select(MailboxName(label), []))
                guard sel.ok else { throw IMAPError("select label: \(sel.text)") }
                let found = searchUIDs(try await conn.run(.uidSearch(key: .header("Message-ID", ByteBuffer(string: fixtures[0].messageID)))))
                // Remove the label again: \Deleted + EXPUNGE inside a label mailbox.
                var removed = false
                if !found.isEmpty {
                    _ = try await conn.run(.uidStore(uidSet(found), [], .flags(.add(silent: true, list: [.deleted]))))
                    removed = try await conn.run(hasCap("UIDPLUS") ? .uidExpunge(uidSet(found)) : .expunge).ok
                }
                let back = try await conn.run(.select(MailboxName(testMailbox), []))
                guard back.ok else { throw IMAPError("reselect test mailbox: \(back.text)") }
                let still = searchUIDs(try await conn.run(.uidSearch(key: .header("Message-ID", ByteBuffer(string: fixtures[0].messageID)))))
                return (true, ["inLabel": found.count, "labelRemoved": removed, "stillInFolder": still.count])
            })
        }
    }

    // Delete → restore cycle (dedicated test accounts only): MOVE to \Trash, re-APPEND with the
    // original date, then purge the trashed copy.
    if !isProton, let trash = specialUse("\\trash"), let f5 = fixtures.last, let uid5 = uidByMessageID[f5.messageID] {
        _ = await rep.timed("move → \(trash)", {
            try guardAllowed(trash, a)
            guard hasCap("MOVE") else { throw IMAPError("no MOVE capability") }
            let r = try await conn.run(.uidMove(uidSet([uid5]), MailboxName(trash)))
            guard r.ok else { throw IMAPError(r.text) }
            let left = searchUIDs(try await conn.run(.uidSearch(key: .header("Message-ID", ByteBuffer(string: f5.messageID)))))
            return (true, ["remainingInTest": left.count])
        })
        _ = await rep.timed("restore (APPEND)", {
            let date = ServerMessageDate(ServerMessageDate.Components(year: 2019, month: 3, day: 18, hour: 10, minute: 0, second: 0, timeZoneMinutes: 60)!)
            let r = try await conn.append(to: MailboxName(testMailbox), message: f5.raw, flags: [], date: date)
            guard r.ok else { throw IMAPError(r.text) }
            let uids = appendedUIDs(r)
            let check = uids.isEmpty ? CommandResult() : try await conn.run(.uidFetch(uidSet(uids), [.uid, .internalDate, .bodySection(peek: true, .complete, nil)], []))
            let m = check.fetches.first
            return (true, ["appendUID": uids, "internalDate": m?.internalDate ?? "?",
                           "bytesIdentical": m.map { sha256($0.body) == sha256(f5.raw) } ?? false])
        })
        _ = await rep.timed("purge from \(trash)", {
            let sel = try await conn.run(.select(MailboxName(trash), []))
            guard sel.ok else { throw IMAPError(sel.text) }
            let found = searchUIDs(try await conn.run(.uidSearch(key: .header("Message-ID", ByteBuffer(string: f5.messageID)))))
            if !found.isEmpty {
                _ = try await conn.run(.uidStore(uidSet(found), [], .flags(.add(silent: true, list: [.deleted]))))
                _ = try await conn.run(hasCap("UIDPLUS") ? .uidExpunge(uidSet(found)) : .expunge)
            }
            let after = searchUIDs(try await conn.run(.uidSearch(key: .header("Message-ID", ByteBuffer(string: f5.messageID)))))
            return (true, ["inTrashBefore": found.count, "inTrashAfter": after.count])
        })
    }

    await conn.close()
    return rep
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: S1IMAP <account-id> [--out file]"); exit(2) }
let config = try JSONDecoder().decode(ConfigFile.self, from: Data(contentsOf: configDir.appending(path: "test-accounts.json")))
guard let account = config.accounts.first(where: { $0.id == args[1] }) else { print("unknown account \(args[1])"); exit(2) }

print("== S1 probe: \(account.id) (\(account.kind)) \(account.host):\(account.port)")
let report = await probe(account)
let failed = report.steps.filter { ($0["ok"] as? Bool) == false }.count
print("== \(report.steps.count) steps, \(failed) failed")
if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    var out = report.fields
    out["steps"] = report.steps
    try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[i + 1]))
}

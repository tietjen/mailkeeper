import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Action queue (ADR-0006)")
struct ActionQueueTests {
    static func job(_ n: Int = 3) -> ActionJob {
        ActionJob(kind: .serverDelete, title: "Test", query: "sender:x@y.de", graceDays: 30, items: (0..<n).map {
            ActionItem(id: $0, sha256: String(repeating: "a", count: 64), messageID: "<\($0)@t>", size: 100, date: nil,
                       location: ServerLocation(account: "imap", mailbox: "INBOX", uidValidity: 7, uid: UInt32($0 + 1)))
        })
    }

    @Test func stateChangesSurviveReloadTornLinesAndBrokenFiles() throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "aq"), create: true)
        let store = ActionStore(layout: layout)
        let job = Self.job()
        try store.create(job)
        try store.record(job: job.id, item: 0, state: .claimed)
        try store.record(job: job.id, item: 0, state: .done)
        try store.record(job: job.id, item: 1, state: .failed, reason: "Verbindung weg")
        var loaded = try store.load(job.id)
        #expect(loaded.items.map(\.state) == [.done, .failed, .planned])
        #expect(loaded.items[1].reason == "Verbindung weg" && !loaded.isFinished && loaded.open.map(\.id) == [2])
        // a crash mid-write leaves a torn line: skipped, and the next change still lands
        let file = store.directory.appending(path: "\(job.id.uuidString).jsonl")
        let fh = try FileHandle(forWritingTo: file)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("{\"type\":\"state\",\"it".utf8))
        try fh.close()
        try store.record(job: job.id, item: 2, state: .claimed)
        loaded = try store.load(job.id)
        #expect(loaded.items.map(\.state) == [.done, .failed, .claimed])
        try store.cancel(job: job.id)
        #expect(try store.load(job.id).isFinished)
        #expect(posixMode(file) == 0o600 && posixMode(store.directory) == 0o700)
        // an unreadable job file is moved aside, the others still load
        try Data("not json\n".utf8).write(to: store.directory.appending(path: "\(UUID().uuidString).jsonl"))
        let (jobs, broken) = store.load()
        #expect(jobs.map(\.id) == [job.id] && broken.count == 1)
        #expect(FileManager.default.fileExists(atPath: broken[0].path))
    }

    @Test func auditHoldsMetadataOnly() throws {
        let audit = AuditLog(url: tempDir().appending(path: "logs/audit.jsonl"))
        var job = Self.job(1)
        job.title = "Geheimer Betreff Titel"
        var item = job.items[0]
        item.state = .done
        try audit.append(job: job, item: item)
        let entries = audit.entries()
        #expect(entries.count == 1 && entries[0].uid == 1 && entries[0].result == .done && entries[0].mailbox == "INBOX")
        let raw = String(decoding: try Data(contentsOf: audit.url), as: UTF8.self)
        #expect(!raw.contains("Geheimer") && !raw.contains("sender:"))
        #expect(posixMode(audit.url) == 0o600)
    }
}

@Suite("Planning a server delete")
struct ServerDeletePlanTests {
    @Test func everyPreconditionIsCheckedAndExplained() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "pl"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        for id in ["imap", "other", "backup"] { try await writer.register(AccountInfo(id: id, kind: "imap", name: id)) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09
        let old = Date(timeIntervalSince1970: 1_700_000_000), recent = now.addingTimeInterval(-5 * 86_400)
        func loc(_ account: String, _ uid: UInt32?, date: Date?, flags: [String] = []) -> LocationInfo {
            LocationInfo(account: account, mailbox: "INBOX", uidValidity: uid == nil ? nil : 9, uid: uid,
                         providerID: uid == nil ? "file-\(UUID())" : nil, internalDate: date, flags: flags)
        }
        _ = try await writer.ingest([
            (sampleMessage(id: "<a@t.test>", subject: "A old"), loc("imap", 1, date: old)),
            (sampleMessage(id: "<b@t.test>", subject: "B recent"), loc("imap", 2, date: recent)),
            (sampleMessage(id: "<c@t.test>", subject: "C flagged"), loc("imap", 3, date: old, flags: ["\\Flagged"])),
            (sampleMessage(id: "<d@t.test>", subject: "D imported"), loc("backup", nil, date: old)),
            (sampleMessage(id: "<e@t.test>", subject: "E other"), loc("other", 5, date: old)),
            (sampleMessage(id: "<f@t.test>", subject: "F gone"), loc("imap", 6, date: old)),
        ])
        _ = try await writer.markGone(account: "imap", mailbox: "INBOX", uidValidity: 9, uids: [6])
        let r = try ArchiveReader(layout: layout)
        let accounts = [AccountConfig.imap(id: "imap", username: "u", host: "mail.example.test")]
        let (job, summary) = try r.planServerDelete(MessageFilter(), title: "Alles", accounts: accounts, now: now)
        let bySubjectUID = Dictionary(uniqueKeysWithValues: job.items.map { ($0.location!.uid, $0) })
        #expect(job.items.count == 4)  // D has no server location, F is gone
        #expect(bySubjectUID[1]?.state == .planned && bySubjectUID[1]?.messageID == "<a@t.test>")
        #expect(bySubjectUID[2]?.reason == "erst seit weniger als 30 Tagen auf dem Server (Schonfrist)")
        #expect(bySubjectUID[3]?.reason == "markiert")
        #expect(bySubjectUID[5]?.reason == "Konto ist hier nicht eingerichtet")
        #expect(summary.messages == 6 && summary.archiveOnly == 2 && summary.perAccount == ["imap": 1])
        #expect(job.count(.planned) == 1 && job.openBytes > 0 && job.reasons.count == 3)
        // a shorter grace period lets the recent one through
        let (short, _) = try r.planServerDelete(MessageFilter(), title: "x", accounts: accounts, graceDays: 1, now: now)
        #expect(short.count(.planned) == 2)
    }
}

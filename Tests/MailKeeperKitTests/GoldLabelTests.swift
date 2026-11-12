import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Privates Gold-Set (6.6b)")
struct GoldLabelTests {
    @Test func labelsLiveBesideTheArchiveAndNeverInTheIndex() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "gold"), create: true)
        let store = GoldStore(layout: layout)
        var labels = try store.load()
        #expect(labels.labels.isEmpty)
        labels.set(GoldLabel(identity: "mid:<a@t.test>", category: .work, phishing: false))
        labels.skip("mid:<b@t.test>")
        labels.set(GoldLabel(identity: "mid:<b@t.test>", category: .spam, phishing: true))  // a label ends the skip
        labels.set(GoldLabel(identity: "mid:<a@t.test>", category: .personal, phishing: false))  // and replaces the old label
        try store.save(labels)
        let back = try store.load()
        #expect(back.labels.count == 2 && back.label(of: "mid:<a@t.test>")?.category == .personal && back.skipped.isEmpty)
        #expect(back.seen == ["mid:<a@t.test>", "mid:<b@t.test>"])
        let mode = try FileManager.default.attributesOfItem(atPath: store.labelsURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        struct Run: Codable, Equatable { var mode: String; var right: Int }
        try store.appendRun(Run(mode: "a", right: 3))
        try store.appendRun(Run(mode: "b", right: 4))
        #expect(store.runs(as: Run.self) == [Run(mode: "a", right: 3), Run(mode: "b", right: 4)])
        // a torn last line is ended before the next run, and left out when reading
        let handle = try FileHandle(forWritingTo: store.runsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"mode":"c","ri"#.utf8))
        try handle.close()
        try store.appendRun(Run(mode: "d", right: 5))
        #expect(store.runs(as: Run.self) == [Run(mode: "a", right: 3), Run(mode: "b", right: 4), Run(mode: "d", right: 5)])
    }

    @Test("Review 6.6 S4/S5: a broken gold.json is an error, never overwritten; a run file that cannot be opened is never replaced")
    func brokenFilesAreNotLost() throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "goldb"), create: true)
        let store = GoldStore(layout: layout)
        try Data(#"{"labels":[{"identity":"x","category":"futurecategory","phishing":false,"time":"2026-10-13T08:00:00Z"}],"skipped":[]}"#.utf8)
            .write(to: store.labelsURL)
        #expect(throws: ArchiveError.self) { _ = try store.load() }
        try store.appendRun(["mode": "a"])
        // root writes through 0400 — CI's Linux containers run as root; macOS covers this part.
        guard getuid() != 0 else { return }
        let before = try Data(contentsOf: store.runsURL)
        chmod(store.runsURL.path, 0o400)
        defer { chmod(store.runsURL.path, 0o600) }
        #expect(throws: ArchiveError.self) { try store.appendRun(["mode": "b"]) }
        #expect(try Data(contentsOf: store.runsURL) == before)
    }

    @Test func candidatesAreSpreadOverSendersAndBuckets() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "goldc"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "imap", kind: "imap", name: "I"))
        var batch: [(data: Data, location: LocationInfo)] = []
        var uid: UInt32 = 1
        func add(_ id: String, _ from: String, _ mailbox: String = "INBOX") {
            batch.append((sampleMessage(id: "<\(id)@t.test>", subject: id, from: from), LocationInfo(account: "imap", mailbox: mailbox, uidValidity: 1, uid: uid)))
            uid += 1
        }
        for n in 0..<20 { add("big\(n)", "news\(n % 2)@big-shop.example") }  // one big sender domain
        add("friend", "max@familie.example")
        add("bank", "info@musterbank.example")
        add("junk", "win@lotto.example", "Junk")
        add("mine", "me@own.example", "Sent")
        _ = try await writer.ingest(batch)
        let r = try ArchiveReader(layout: layout)
        let ids = try r.goldCandidates(limit: 10, excluding: [])
        let subjects = try r.summaries(ids).compactMap(\.subject)
        #expect(subjects.filter { $0.hasPrefix("big") }.count == 1)  // one per domain
        #expect(Set(subjects).isSuperset(of: ["friend", "bank", "junk"]) && !subjects.contains("mine"))  // never sent mail
        // a domain labelled before does not come back with its next mail
        let bigID = try #require(try r.messageIDs(MessageFilter(text: "subject:big0 ")).first)
        let bigIdentity = try #require(try r.identities(of: [bigID]).first)
        #expect(!(try r.summaries(try r.goldCandidates(limit: 10, excluding: [bigIdentity])).contains { $0.subject?.hasPrefix("big") == true }))
        let junkID = try #require(try r.messageIDs(MessageFilter(text: "subject:junk ")).first)
        let junkIdentity = try #require(try r.identities(of: [junkID]).first)
        #expect(!(try r.summaries(try r.goldCandidates(limit: 10, excluding: [junkIdentity])).contains { $0.subject == "junk" }))
    }
}

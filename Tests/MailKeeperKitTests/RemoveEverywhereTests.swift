import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Komplett entfernen und Papierkorb-Frist")
struct RemoveEverywhereTests {
    /// The archive half is planned with the server half, so a mail still on a server is planned
    /// too; when it runs, the writer takes only what the server half took off the server.
    @Test func theArchiveHalfTakesWhatNoServerHoldsAnyMore() async throws {
        let (layout, writer, r) = try await ArchiveTrashTests.archive()  // A: imap+backup, B: imap, C: backup only
        let (plain, _) = try r.planArchiveDelete(MessageFilter(), title: "alle")
        #expect(plain.count(.planned) == 1 && plain.count(.skipped) == 2)  // alone: only C
        let (job, summary) = try r.planArchiveDelete(MessageFilter(), title: "alle", afterServerDelete: true)
        #expect(job.count(.planned) == 3 && summary.archiveOnly == 1)
        // the server half took B off its server, A stayed (grace period, flagged, unreachable …)
        _ = try await writer.markGone(account: "imap", mailbox: "INBOX", uidValidity: 9, uids: [2])
        let store = ActionStore(layout: layout)
        try store.create(job)
        let done = try await ArchiveDeleteExecutor(writer: writer, store: store, audit: AuditLog(url: tempDir().appending(path: "re.jsonl"))).run(job.id)
        let a = try ArchiveTrashTests.identity(r, "A")
        #expect(done.items.filter { $0.state == .done }.count == 2)
        #expect(done.items.first { $0.identity == a }.map { $0.state == .skipped && $0.reason == ArchiveReader.stillOnServer } == true)
        #expect(try r.stats().trashed == 2)
        #expect(try ArchiveTrashTests.subjects(r) == ["A"])
    }

    @Test("The archive half leaves what the server half did not verifiably take off, and what had moved")
    func theArchiveHalfFollowsTheServerHalf() {
        func item(_ n: Int, _ mid: String?, _ sha: String, state: ActionItem.State = .planned, reason: String? = nil, server: Bool) -> ActionItem {
            ActionItem(id: n, sha256: sha, messageID: mid, size: 1, date: nil,
                       location: server ? ServerLocation(account: "a", mailbox: "INBOX", uidValidity: 1, uid: UInt32(n + 1)) : nil,
                       identity: server ? nil : "id\(n)", state: state, reason: reason)
        }
        let server = ActionJob(kind: .serverDelete, title: "t", query: nil, graceDays: 30, items: [
            item(0, "<a>", "sa", state: .done, server: true),
            item(1, "<b>", "sb", state: .failed, reason: "vom Server abgelehnt", server: true),
            item(2, "<c>", "sc", state: .skipped, reason: "Schonfrist", server: true),
            item(3, "<d>", "sd", state: .done, reason: ServerDeleteExecutor.alreadyGone, server: true),
            item(4, nil, "se", state: .failed, server: true),  // no Message-ID: the blob ties it
        ])
        let archive = ActionJob(kind: .archiveDelete, title: "t", query: nil, graceDays: nil, items: [
            item(0, "<a>", "other-blob", server: false),  // same mail, another blob: the Message-ID ties it
            item(1, "<b>", "sb", server: false),
            item(2, "<c>", "sc", server: false),
            item(3, "<d>", "sd", server: false),
            item(4, nil, "se", server: false),
            item(5, "<f>", "sf", server: false),  // only in the archive: goes
        ])
        let half = archive.archiveHalf(after: server)
        #expect(half.items.map(\.state) == [.planned, .skipped, .skipped, .skipped, .skipped, .planned])
        #expect(half.items[1].reason == ArchiveReader.stillOnServer && half.items[3].reason == ActionJob.notThereAnyMore)
        #expect(half.id == archive.id)
    }

    @Test func aShorterPeriodCountsAndPurgesWhatIsPastIt() async throws {
        let (_, writer, r) = try await ArchiveTrashTests.archive()
        let now = Date()
        try await writer.trash([try ArchiveTrashTests.identity(r, "C")], time: now.addingTimeInterval(-20 * 86_400).timeIntervalSince1970)
        #expect(try r.trashedCount(olderThan: 30, now: now) == 0)
        #expect(try r.trashedCount(olderThan: 14, now: now) == 1)
        #expect(try await writer.purgeExpired(days: 30, now: now).messages == 0)
        #expect(try await writer.purgeExpired(days: 14, now: now).messages == 1)
        #expect(try r.trashedCount(olderThan: 1, now: now) == 0)
    }

    @Test func settingsLiveInTheArchiveAndDefaultTo30Days() throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "settings"), create: true)
        let store = ArchiveSettingsStore(layout: layout)
        #expect(store.load().settings.trashDays == 30 && !store.load().unreadable)  // no file: as it always was
        try store.save(ArchiveSettings(trashDays: 7))
        #expect(store.load().settings.trashDays == 7)
        try store.save(ArchiveSettings(trashDays: nil))
        #expect(store.load().settings.trashDays == nil)  // only by hand
        #expect(try String(contentsOf: store.url, encoding: .utf8).contains("null"))
        let decode = { (json: String) in try JSONDecoder().decode(ArchiveSettings.self, from: Data(json.utf8)) }
        #expect(try decode("{}").trashDays == 30)  // an older file without the key
        #expect(try decode(#"{"trashDays": 0}"#).trashDays == 1)  // an edited file: 0 does not mean "at once forever"
        #expect(try decode(#"{"trashDays": 999999}"#).trashDays == 3650)
        // there but unreadable: only by hand, never 30 days by accident (review: fail closed)
        try Data("kein json".utf8).write(to: store.url)
        #expect(store.load().settings.trashDays == nil && store.load().unreadable)
    }
}

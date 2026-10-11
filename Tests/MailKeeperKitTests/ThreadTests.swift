import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Conversations")
struct ThreadTests {
    /// A ← B ← C (C references both), D alone, E and F reply to the same missing original,
    /// G and H share only an implausible reference `<1>`.
    static let mails: [(subject: String, id: String, headers: String)] = [
        ("A", "<a@t.test>", ""),
        ("B", "<b@t.test>", "In-Reply-To: <a@t.test>\nReferences: <a@t.test>\n"),
        ("C", "<c@t.test>", "References: <a@t.test> <b@t.test>\n"),
        ("D", "<d@t.test>", ""),
        ("E", "<e@t.test>", "References: <missing@t.test>\n"),
        ("F", "<f@t.test>", "In-Reply-To: <missing@t.test>\n"),
        ("G", "<g@t.test>", "References: <1>\n"),
        ("H", "<h@t.test>", "References: <1>\n"),
    ]
    static let expected: Set<Set<String>> = [["A", "B", "C"], ["D"], ["E", "F"], ["G"], ["H"]]

    static func archive(order: [Int]) async throws -> (ArchiveLayout, ArchiveWriter) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "t"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "a", kind: "imap", name: "A"))
        for (n, i) in order.enumerated() {
            let m = mails[i]
            _ = try await writer.ingest(sampleMessage(id: m.id, subject: m.subject, extraHeaders: m.headers),
                                        at: LocationInfo(account: "a", mailbox: "INBOX", providerID: "\(n)"))
        }
        return (layout, writer)
    }

    static func partition(_ reader: ArchiveReader) throws -> Set<Set<String>> {
        let all = try reader.summaries(try reader.messageIDs(MessageFilter()))
        return Set(try all.map { Set(try reader.thread(of: $0.id).compactMap(\.subject)) })
    }

    @Test func partitionDoesNotDependOnArrivalOrder() async throws {
        for order in [Array(0..<8), Array((0..<8).reversed()), [2, 7, 4, 0, 6, 3, 1, 5]] {
            let (layout, _) = try await Self.archive(order: order)
            #expect(try Self.partition(ArchiveReader(layout: layout)) == Self.expected, "\(order)")
        }
    }

    @Test func rebuildReproducesConversations() async throws {
        let (layout, writer) = try await Self.archive(order: [2, 7, 4, 0, 6, 3, 1, 5])
        _ = try await writer.rebuildIndex()
        #expect(try Self.partition(ArchiveReader(layout: layout)) == Self.expected)
    }

    @Test("Migration v2 → current links existing messages from their stored headers")
    func migrationBackfills() async throws {
        let (layout, writer) = try await Self.archive(order: Array(0..<8))
        _ = writer
        let raw = try Database(path: layout.indexURL.path)
        try raw.execute("""
            DROP TABLE classifications; DROP TABLE tombstones; DROP TABLE tombstone_locations; DROP INDEX messages_trashed;
            ALTER TABLE messages DROP COLUMN trashed;
            DROP TABLE attachment_text; DROP TABLE attachment_text_fts;
            DROP INDEX messages_thread; DROP TABLE message_refs; ALTER TABLE messages DROP COLUMN thread_id;
            PRAGMA user_version = 2;
            """)
        let reader = try ArchiveReader(layout: layout)  // migrates
        #expect(try raw.queryOne("PRAGMA user_version") { $0.int(0) } == Int64(Schema.currentVersion))
        #expect(try Self.partition(reader) == Self.expected)
    }

    @Test func queriesCountsAndStableNames() async throws {
        let (layout, _) = try await Self.archive(order: Array(0..<8))
        let r = try ArchiveReader(layout: layout)
        let subjects = { (q: String) in Set(try r.summaries(try r.messageIDs(MessageFilter(text: q + " "))).compactMap(\.subject)) }
        #expect(try subjects("thread:<a@t.test>") == ["A", "B", "C"])
        #expect(try subjects("thread:f@t.test") == ["E", "F"])
        #expect(try subjects("konversation:<d@t.test>") == ["D"])
        #expect(try subjects("thread:<missing@t.test>").isEmpty)  // not in the archive itself
        let byName = Dictionary(uniqueKeysWithValues: try r.summaries(try r.messageIDs(MessageFilter())).map { ($0.subject ?? "", $0) })
        #expect(byName["A"]?.threadCount == 3 && byName["D"]?.threadCount == 1 && byName["E"]?.threadCount == 2)
        #expect(try r.thread(of: byName["C"]!.id).map(\.subject) == ["A", "B", "C"])  // oldest first, then by id
        #expect(try r.threadQuery(of: byName["C"]!.id) == "thread:<c@t.test>")  // its own id first
        #expect(try r.detail(byName["B"]!.id)?.summary.threadCount == 3)
        #expect(try r.queryPlan(MessageFilter(text: "thread:<a@t.test>")).contains { $0.contains("LIST SUBQUERY") })
    }

    @Test func implausibleAndOwnReferencesAreIgnored() {
        #expect(Threads.references(inReplyTo: "<x@y.z>", references: ["<1>", "<unknown>", "<me@y.z>", "<x@y.z>", "<p@y.z>"],
                                   own: "<me@y.z>") == ["<x@y.z>", "<p@y.z>"])
        let long = (1...30).map { "<r\($0)@y.z>" }
        #expect(Threads.references(inReplyTo: nil, references: long, own: nil) == Array(long.suffix(20)))
    }
}

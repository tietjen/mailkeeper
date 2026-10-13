import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Archiv-Ablage (6.9, ADR-0011)")
struct PlacementTests {
    static func archive() async throws -> (ArchiveLayout, ArchiveWriter, ArchiveReader) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "place"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "imap", kind: "imap", name: "I"))
        _ = try await writer.ingest([
            (sampleMessage(id: "<news@t.test>", subject: "Neue Preise", from: "hello@shop.example"), LocationInfo(account: "backup", mailbox: "Junk", providerID: "n")),
            (sampleMessage(id: "<hallo@t.test>", subject: "Hallo"), LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 7, uid: 1)),
            (sampleMessage(id: "<lotto@t.test>", subject: "Gewinn"), LocationInfo(account: "imap", mailbox: "Spam", uidValidity: 5, uid: 2)),
        ])
        try await writer.setMailboxRoles(account: "imap", [RemoteMailbox(name: "Spam", specialUse: [.junk]), RemoteMailbox(name: "INBOX")])
        return (layout, writer, try ArchiveReader(layout: layout))
    }

    static func id(_ r: ArchiveReader, _ subject: String) throws -> Int64 {
        try #require(try r.messageIDs(MessageFilter(text: "subject:\"\(subject)\" ")).first)
    }

    @Test func anImportFiledOutOfJunkLeavesTheSpamFolder() async throws {
        let (_, writer, r) = try await Self.archive()
        let news = try Self.id(r, "Neue Preise")
        let identity = try #require(try r.identities(of: [news]).first)
        #expect(try r.count(MessageFilter(text: "is:junk ", ids: [news])) == 1)
        #expect(try await writer.place(identities: [identity], mailbox: "Newsletter") == 1)
        // the archive's view follows the placement
        #expect(try r.count(MessageFilter(text: "is:junk ", ids: [news])) == 0)
        #expect(try r.messageIDs(MessageFilter(text: "in:newsletter ")) == [news])
        #expect(try r.messageIDs(MessageFilter(text: "in:junk ")).isEmpty)
        #expect(try r.messageIDs(MessageFilter(account: "backup", mailbox: "Newsletter")) == [news])
        #expect(try r.messageIDs(MessageFilter(account: "backup", mailbox: "Junk")).isEmpty)
        let boxes = try #require(try r.accounts().first { $0.id == "backup" }).mailboxes
        #expect(boxes.map(\.name) == ["Newsletter"] && boxes.first?.count == 1)
        let detail = try #require(try r.detail(news))
        #expect(detail.placements == ["backup": "Newsletter"] && detail.filed.map(\.mailbox) == ["Newsletter"])
        #expect(detail.locations.map(\.mailbox) == ["Junk"])  // the fact stays: where it was seen
        // history stays too: it was in a spam folder once
        #expect(try r.count(MessageFilter(text: "is:war-im-spam ", ids: [news])) == 1)
        // filed into a spam-named folder, it is in a spam folder again; back where it was seen, too
        try await writer.place(identities: [identity], mailbox: "Spam")
        #expect(try r.count(MessageFilter(text: "is:junk ", ids: [news])) == 1)
        try await writer.place(identities: [identity], mailbox: nil)
        #expect(try r.detail(news)?.placements.isEmpty == true && r.count(MessageFilter(text: "is:junk ", ids: [news])) == 1)
    }

    @Test func aServerMailKeepsItsServerFactsWhateverTheArchiveSays() async throws {
        let (_, writer, r) = try await Self.archive()
        let lotto = try Self.id(r, "Gewinn")
        let identity = try #require(try r.identities(of: [lotto]).first)
        try await writer.place(identities: [identity], mailbox: "Projekte")
        // it lies in the server's spam folder: "Spam-Prüfung" keeps it until it leaves it there
        #expect(try r.count(MessageFilter(text: "is:junk ", ids: [lotto])) == 1)
        #expect(try r.messageIDs(MessageFilter(text: "in:projekte ")) == [lotto])
        #expect(try r.messageIDs(MessageFilter(account: "imap", mailbox: "Spam")).isEmpty)  // the archive files it elsewhere
        let detail = try #require(try r.detail(lotto))
        #expect(detail.place == .serverAndArchive && detail.filed.first?.mailbox == "Projekte" && detail.filed.first?.onServer == false)
    }

    @Test func placementsAreJournalledAndSurviveARebuild() async throws {
        let (layout, writer, r) = try await Self.archive()
        let news = try Self.id(r, "Neue Preise"), hallo = try Self.id(r, "Hallo")
        let ids = try r.identities(of: [news, hallo])
        try await writer.place(identities: ids, mailbox: "Archiv/2026")
        try await writer.place(identities: [try #require(try r.identities(of: [hallo]).first)], mailbox: nil)
        _ = try await writer.rebuildIndex()
        let rebuiltNews = try Self.id(r, "Neue Preise"), rebuiltHallo = try Self.id(r, "Hallo")
        #expect(try r.detail(rebuiltNews)?.placements == ["backup": "Archiv/2026"])
        #expect(try r.detail(rebuiltHallo)?.placements.isEmpty == true)  // the later "back" wins
        // in the account's own journal
        let files = try FileManager.default.contentsOfDirectory(at: layout.journalURL.appending(path: "backup"), includingPropertiesForKeys: nil)
        #expect(try files.contains { try String(contentsOf: $0, encoding: .utf8).contains("placed") })
        await #expect(throws: ArchiveError.self) { try await writer.place(identities: ids, mailbox: "   ") }
        #expect(try await writer.place(identities: ["mid:<nobody@t.test>"], mailbox: "X") == 0)
    }
}

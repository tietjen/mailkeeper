import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Gedächtnis (6.1)")
struct MemoryTests {
    static func archive() async throws -> (ArchiveLayout, ArchiveWriter, ArchiveReader) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "mem"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest([
            (sampleMessage(id: "<a@t.test>", subject: "Angebot Dachsanierung", from: "Max Muster <max@handwerk.example>"),
             LocationInfo(account: "x", mailbox: "INBOX", providerID: "1")),
            (sampleMessage(id: "<b@t.test>", subject: "Gewinn!", from: "win@lotto.example"), LocationInfo(account: "x", mailbox: "Junk", providerID: "2")),
        ])
        _ = try await writer.classifyHeuristically()
        return (layout, writer, try ArchiveReader(layout: layout))
    }

    @Test func notesAndExamplesSurviveARebuildAndForgettingSticks() async throws {
        let (_, writer, r) = try await Self.archive()
        let note = try await writer.saveNote(kind: .preference, text: "  Mails vom Steuerberater sind wichtig.\u{0007}  ", subject: "domain:stb.example")
        let term = try await writer.saveNote(kind: .vocabulary, text: "Firma = Konto proton")
        let offer = try #require(try r.messageIDs(MessageFilter(text: "subject:angebot ")).first)
        let lotto = try #require(try r.messageIDs(MessageFilter(text: "subject:gewinn ")).first)
        try await writer.setUserClassification(identity: try #require(try r.identities(of: [offer]).first), category: .work)  // "Art ändern"
        try await writer.confirmNotSpam(identity: try #require(try r.identities(of: [lotto]).first))

        var items = try r.memoryItems()
        #expect(items.count == 4)
        let n = try #require(items.first { $0.id == note })
        #expect(n.kind == .preference && n.provenance == .user && n.content.text == "Mails vom Steuerberater sind wichtig." && n.subject == "domain:stb.example")
        let example = try #require(items.first { $0.kind == .example && $0.content.category == "work" })
        #expect(example.provenance == .feedback && example.subject == "sender:max@handwerk.example" && example.content.domain == "handwerk.example")
        #expect(example.summary.hasPrefix("Arbeit – Angebot") && example.sources.count == 1)
        #expect(items.contains { $0.kind == .example && $0.content.verdict == "ham" && $0.content.category == nil })

        try await writer.saveNote(id: note, kind: .preference, text: "Steuerberater: immer wichtig")  // changed
        try await writer.forgetMemory([term, example.id])
        _ = try await writer.rebuildIndex()

        items = try r.memoryItems()
        #expect(items.count == 2 && items.contains { $0.id == note } && items.contains { $0.content.verdict == "ham" })
        #expect(items.first { $0.id == note }?.content.text == "Steuerberater: immer wichtig")
        #expect(try r.memoryItem(term)?.active == false && r.memoryItem(example.id)?.active == false)
        // the decision on the mail stays; only its use as an example ended — until a new decision
        let rebuilt = try #require(try r.messageIDs(MessageFilter(text: "subject:angebot ")).first)
        #expect(try r.classification(of: rebuilt)?.category == .work)
        try await writer.setUserClassification(identity: try #require(try r.identities(of: [rebuilt]).first), category: .invoice)
        #expect(try r.memoryItem(example.id)?.active == true && r.memoryItem(example.id)?.content.category == "invoice")
    }

    @Test("Art ändern keeps a 'kein Spam' and ends a 'Spam'")
    func aUserCategoryAndTheVerdict() async throws {
        let (_, writer, r) = try await Self.archive()
        let lotto = try #require(try r.messageIDs(MessageFilter(text: "subject:gewinn ")).first)
        let identity = try #require(try r.identities(of: [lotto]).first)
        try await writer.confirmNotSpam(identity: identity)
        try await writer.setUserClassification(identity: identity, category: .newsletter)
        #expect(try r.classification(of: lotto)?.verdict == "ham" && r.classification(of: lotto)?.category == .newsletter)
        try await writer.setUserClassification(identity: identity, category: .spam)
        #expect(try r.classification(of: lotto)?.verdict == "spam")
        #expect(try r.memoryItems().first { $0.kind == .example }?.summary.hasPrefix("Spam – ") == true)  // not "Spam, Spam"
        try await writer.setUserClassification(identity: identity, category: .personal)
        #expect(try r.classification(of: lotto)?.verdict == nil && r.classification(of: lotto)?.source == .user)
    }

    @Test func exportAndImportCarryOnlyNotesAndTerms() async throws {
        let (_, writer, r) = try await Self.archive()
        try await writer.saveNote(kind: .preference, text: "Newsletter nach 90 Tagen vom Server")
        try await writer.saveNote(kind: .vocabulary, text: "Firma = Konto proton", subject: "", scope: "proton")
        let offer = try #require(try r.messageIDs(MessageFilter(text: "subject:angebot ")).first)
        try await writer.setUserClassification(identity: try #require(try r.identities(of: [offer]).first), category: .work)
        let data = try r.exportMemory()
        #expect(String(decoding: data, as: UTF8.self).contains("mailkeeper-memory"))

        let (_, other, r2) = try await Self.archive()
        #expect(try await other.importMemory(data) == 2)  // the example belongs to the other archive
        #expect(try await other.importMemory(data) == 0)  // nothing twice
        #expect(Set(try r2.memoryItems().map(\.kind)) == [.preference, .vocabulary])
        #expect(try r2.memoryItems().first { $0.kind == .vocabulary }?.scope == "proton")
        await #expect(throws: ArchiveError.self) { try await other.importMemory(Data("{}".utf8)) }
        await #expect(throws: ArchiveError.self) { try await other.saveNote(kind: .example, text: "x") }
        await #expect(throws: ArchiveError.self) { try await other.saveNote(kind: .preference, text: "  \n ") }
        let long = try await other.saveNote(kind: .preference, text: String(repeating: "x", count: 2_000))
        #expect(try r2.memoryItem(long)?.content.text?.count == Memory.maxText)
    }

    @Test func theMigrationBringsTheDecisionsAlong() async throws {
        let (layout, writer, r) = try await Self.archive()
        let offer = try #require(try r.messageIDs(MessageFilter(text: "subject:angebot ")).first)
        try await writer.setUserClassification(identity: try #require(try r.identities(of: [offer]).first), category: .work)
        let raw = try Database(path: layout.indexURL.path)
        try raw.execute("DROP TABLE suggestion_sources; DROP TABLE memory_items; PRAGMA user_version = 10;")
        try ArchiveReader.migrate(layout)
        #expect(try ArchiveReader(layout: layout).memoryItems().map(\.content.category) == ["work"])
    }
}

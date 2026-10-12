import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Regeln (6.5b)")
struct RuleTests {
    static func archive() async throws -> (ArchiveLayout, ArchiveWriter, ArchiveReader) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "rules"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "imap", kind: "imap", name: "I"))
        var batch: [(data: Data, location: LocationInfo)] = []
        for n in 0..<4 {
            batch.append((sampleMessage(id: "<li\(n)@t.test>", subject: "Reaktion \(n)", from: "LinkedIn <updates@linkedin.example>"),
                          LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 1, uid: UInt32(n + 1))))
        }
        for n in 0..<2 {
            batch.append((sampleMessage(id: "<sp\(n)@t.test>", subject: "Gewinn \(n)", from: "win@lotto.example"),
                          LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 1, uid: UInt32(n + 10))))
        }
        batch.append((sampleMessage(id: "<x@t.test>", subject: "Andere", from: "x@other.example"), LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 1, uid: 20)))
        _ = try await writer.ingest(batch)
        _ = try await writer.classifyHeuristically()
        return (layout, writer, try ArchiveReader(layout: layout))
    }

    @Test func repeatedDecisionsBecomeSuggestionsAndCategoryRulesLabelByThemselves() async throws {
        let (_, writer, r) = try await Self.archive()
        let linkedin = try r.messageIDs(MessageFilter(text: "sender:updates@linkedin.example "))
        for id in linkedin.prefix(3) { try await writer.setUserClassification(identity: try #require(try r.identities(of: [id]).first), category: .notification) }
        for id in try r.messageIDs(MessageFilter(text: "sender:win@lotto.example ")) {
            try await writer.setUserClassification(identity: try #require(try r.identities(of: [id]).first), category: .spam)
        }
        let other = try #require(try r.messageIDs(MessageFilter(text: "sender:x@other.example ")).first)
        let deletedSha = try #require(try r.detail(other)?.primaryBlob)
        let audit = (0..<3).map { _ in AuditLog.Entry(time: 0, job: UUID(), action: .serverDelete, result: .done, sha256: deletedSha) }
        let suggestions = try r.ruleSuggestions(audit: audit)
        let notif = try #require(suggestions.first { $0.action == .category(.notification) })
        #expect(notif.query == "sender:updates@linkedin.example" && notif.matches == 4 && notif.evidence == "3× „Benachrichtigung“ festgelegt")
        #expect(suggestions.contains { $0.action == .moveToJunk && $0.query == "sender:win@lotto.example" })
        #expect(!suggestions.contains { $0.query == "sender:x@other.example" })  // one mail, three entries: deleted once, not three times

        // accepted: the fourth LinkedIn mail is labelled by the rule; a model does not overwrite it
        let rule = try await writer.saveRule(name: notif.name, query: notif.query, action: notif.action)
        #expect(try await writer.applyCategoryRules() == 1)
        let fourth = linkedin[3]
        #expect(try r.classification(of: fourth)?.source == .rule && r.classification(of: fourth)?.category == .notification)
        try await writer.setClassification(messageID: fourth, category: .personal, source: .endpoint, model: "m", reason: "r", phishing: .suspicious)
        #expect(try r.classification(of: fourth)?.category == .notification && r.classification(of: fourth)?.phishing == .suspicious)
        #expect(try await writer.applyCategoryRules() == 0)  // nothing new
        #expect(try r.ruleSuggestions(audit: []).first { $0.action == .category(.notification) } == nil)  // a rule exists now

        // forgotten: its mails go back to the rules
        try await writer.forgetMemory([rule])
        _ = try await writer.applyCategoryRules()
        #expect(try r.classification(of: fourth)?.source == .heuristic)
    }

    @Test func destructiveRulesOnlyCountWhatIsReadyAndRejectingSticks() async throws {
        let (_, writer, r) = try await Self.archive()
        let id = try await writer.saveRule(name: "Lotto weg", query: "sender:win@lotto.example", action: .moveToJunk)
        let rule = try #require(try r.rules().first { $0.id == id })
        #expect(rule.action.isDestructive && rule.readyQuery == "(sender:win@lotto.example) -is:junk on:server")
        #expect(try r.ready(rule) == 2)
        #expect(try await writer.applyCategoryRules() == 0)  // never acts by itself
        let old = MailRule.Action.serverDelete(days: 30)
        #expect(MailRule.Action(raw: old.raw) == old && MailRule.Action(raw: "serverDelete:0") == nil && MailRule.Action(raw: "rm -rf") == nil)
        try await writer.rejectRule(name: "x", query: "sender:x@other.example", action: .serverDelete(days: 30))
        #expect(try r.rules().count == 1 && r.rules(includeRejected: true).count == 2)
        await #expect(throws: ArchiveError.self) { try await writer.saveRule(name: "alles", query: "  ", action: .moveToJunk) }
        await #expect(throws: ArchiveError.self) { try await writer.saveRule(name: "kaputt", query: "from:(", action: .moveToJunk) }
    }
}

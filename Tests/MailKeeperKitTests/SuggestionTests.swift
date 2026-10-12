import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Aufräum-Vorschläge (6.5a)")
struct SuggestionTests {
    static func mail(_ id: String, from: String, subject: String, date: String, list: Bool = false) -> Data {
        var s = "From: \(from)\nTo: me@own.test\nSubject: \(subject)\nDate: \(date)\nMessage-ID: <\(id)@t.test>\n"
        if list { s += "List-Id: <news.shop.example>\nList-Unsubscribe: <mailto:unsub@shop.example>\n" }
        return Data((s + "\nText\n").utf8)
    }

    @Test func unreadNewslettersOldNotificationsAndWhereTheyLie() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "sug"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let recent = Date.now.addingTimeInterval(-3 * 86_400)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var batch: [(data: Data, location: LocationInfo)] = []
        // 12 unread newsletters, 3 of them still on the server
        for n in 0..<12 {
            batch.append((Self.mail("n\(n)", from: "Shop <news@shop.example>", subject: "Sale \(n)", date: f.string(from: recent.addingTimeInterval(Double(-n) * 86_400)), list: true),
                          n < 3 ? LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 1, uid: UInt32(n + 1)) : LocationInfo(account: "import", mailbox: "INBOX", providerID: "n\(n)")))
        }
        // 9 newsletters read by the user: no suggestion
        for n in 0..<9 {
            batch.append((Self.mail("r\(n)", from: "Blog <blog@read.example>", subject: "Post \(n)", date: f.string(from: recent), list: true),
                          LocationInfo(account: "import", mailbox: "INBOX", providerID: "r\(n)", flags: ["\\Seen"])))
        }
        // 25 old notifications
        for n in 0..<25 {
            batch.append((Self.mail("o\(n)", from: "noreply@monitor.example", subject: "Alert \(n)", date: "Thu, 14 Mar 2019 10:00:00 +0100"),
                          LocationInfo(account: "import", mailbox: "INBOX", providerID: "o\(n)")))
        }
        try await writer.register(AccountInfo(id: "imap", kind: "imap", name: "I"))
        _ = try await writer.ingest(batch)
        let r = try ArchiveReader(layout: layout)
        for id in try r.messageIDs(MessageFilter(text: "subject:alert ")) {
            try await writer.setClassification(messageID: id, category: .notification, source: .heuristic, model: nil, reason: nil)
        }
        let suggestions = try r.cleanupSuggestions()
        let shop = try #require(suggestions.first { $0.kind == .unreadList })
        #expect(shop.count == 12 && shop.onServer == 3 && shop.archiveOnly == 9 && shop.group?.key == "news@shop.example")
        #expect(shop.reason.contains("100 % ungelesen") && shop.reason.contains("3 noch auf dem Server") && shop.reason.contains("Abmelden"))
        #expect(try r.count(MessageFilter(text: shop.query + " ")) == 12)  // "Ansehen" shows exactly them
        #expect(!suggestions.contains { $0.group?.key == "blog@read.example" })
        let old = try #require(suggestions.first { $0.kind == .oldNotifications })
        #expect(old.count == 25 && old.onServer == 0 && old.reason.contains("keine mehr auf einem Server"))
        #expect(!suggestions.contains { $0.kind == .largeOld || $0.kind == .oldSpam })  // below their minimum
    }
}

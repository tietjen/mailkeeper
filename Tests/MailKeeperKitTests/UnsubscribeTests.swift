import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Abmelden mit Prüfung (6.5c)")
struct UnsubscribeTests {
    static func mail(_ id: String, unsubscribe: String, post: Bool, auth: String?, from: String = "News <news@shop.example>") -> Data {
        var s = "From: \(from)\nTo: me@own.test\nSubject: Angebote \(id)\nDate: Thu, 14 Mar 2024 10:00:00 +0100\nMessage-ID: <\(id)@t.test>\n"
        s += "List-Unsubscribe: \(unsubscribe)\n"
        if post { s += "List-Unsubscribe-Post: List-Unsubscribe=One-Click\n" }
        if let auth { s = "Authentication-Results: \(auth)\n" + s }
        return Data((s + "\nText\n").utf8)
    }

    @Test func oneClickOnlyWhenSignedLockedWhenItLooksWrong() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "unsub"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let signed = "mail.own.test; dkim=pass header.d=shop.example; spf=pass; dmarc=pass header.from=shop.example"
        let mails: [(String, String, Bool, String?)] = [
            ("ok", "<https://esp.example/u?id=1>, <mailto:u@shop.example>", true, signed),
            ("unsigned", "<https://esp.example/u?id=2>", true, "mail.own.test; dkim=none; dmarc=none"),
            ("mailonly", "<mailto:u@shop.example?subject=unsub>", false, signed),
            ("ip", "<https://192.168.1.20/u>", true, signed),
            ("phish", "<https://esp.example/u?id=3>", true, signed),
            ("spam", "<https://esp.example/u?id=4>", true, signed),
            ("junk", "<https://esp.example/u?id=5>", true, signed),
            ("none", "<javascript:alert(1)>", false, signed),
        ]
        _ = try await writer.ingest(mails.enumerated().map { n, m in
            (Self.mail(m.0, unsubscribe: m.1, post: m.2, auth: m.3),
             LocationInfo(account: "x", mailbox: m.0 == "junk" ? "Junk" : "INBOX", providerID: "\(n)"))
        })
        try AccountStore(layout: layout).save([AccountConfig.imap(id: "x", username: "u", host: "imap.own.test")])
        let r = try ArchiveReader(layout: layout)
        let id = { (key: String) in try #require(try r.messageIDs(MessageFilter(text: "msgid:\(key)@t.test ")).first) }
        try await writer.setClassification(messageID: try id("phish"), category: .accountSecurity, source: .endpoint, model: "m", reason: "r", phishing: .likely)
        try await writer.setUserClassification(identity: try #require(try r.identities(of: [try id("spam")]).first), category: .spam)

        let ok = try #require(try r.unsubscribeAssessment(for: try id("ok")))
        #expect(ok.method == .oneClick(URL(string: "https://esp.example/u?id=1")!) && !ok.isBlocked && ok.target == "esp.example")
        #expect(ok.notes.contains { $0.contains("läuft über esp.example, nicht über shop.example") })
        let unsigned = try #require(try r.unsubscribeAssessment(for: try id("unsigned")))
        #expect(unsigned.method == .web(URL(string: "https://esp.example/u?id=2")!) && unsigned.notes.contains { $0.hasPrefix("Ein-Klick-Abmeldung angeboten") })
        #expect(try r.unsubscribeAssessment(for: try id("mailonly"))?.method == .mail(URL(string: "mailto:u@shop.example?subject=unsub")!))
        #expect(try r.unsubscribeAssessment(for: try id("ip"))?.blocked.first?.hasPrefix("Der Abmeldelink ist auffällig") == true)
        #expect(try r.unsubscribeAssessment(for: try id("phish"))?.blocked.first?.hasPrefix("Die KI hält die Mail für Phishing") == true)
        #expect(try r.unsubscribeAssessment(for: try id("spam"))?.isBlocked == true)
        #expect(try r.unsubscribeAssessment(for: try id("junk"))?.isBlocked == true)
        #expect(try r.unsubscribeAssessment(for: try id("none")) == nil)  // nothing usable to offer
        // the user's "kein Spam" lifts the spam lock of a mail in the spam folder
        try await writer.confirmNotSpam(identity: try #require(try r.identities(of: [try id("junk")]).first))
        #expect(try r.unsubscribeAssessment(for: try id("junk"))?.isBlocked == false)
    }
}

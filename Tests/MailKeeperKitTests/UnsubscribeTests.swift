import Foundation
import Synchronization
import Testing
@testable import MailKeeperKit

@Suite("Abmelden mit Prüfung (6.5c)")
struct UnsubscribeTests {
    static let signedHeaders = "DKIM-Signature: v=1; a=rsa-sha256; d=shop.example; s=s1;\n h=from:to:subject:list-unsubscribe:list-unsubscribe-post; bh=x; b=y\n"

    /// `top`: lines put above everything (as on the way: a replayed mail gets them on top).
    static func mail(_ id: String, unsubscribe: String, post: Bool, auth: String?, from: String = "News <news@shop.example>",
                     dkim: String? = signedHeaders, top: String = "") -> Data {
        var s = "From: \(from)\nTo: me@own.test\nSubject: Angebote \(id)\nDate: Thu, 14 Mar 2024 10:00:00 +0100\nMessage-ID: <\(id)@t.test>\n"
        s += "List-Unsubscribe: \(unsubscribe)\n"
        if post { s += "List-Unsubscribe-Post: List-Unsubscribe=One-Click\n" }
        if let dkim { s = dkim + s }
        s = top + s
        if let auth { s = "Authentication-Results: \(auth)\n" + s }
        return Data((s + "\nText\n").utf8)
    }

    static let signed = "mail.own.test; dkim=pass header.d=shop.example; spf=pass; dmarc=pass header.from=shop.example"

    static func archive(_ mails: [(String, String, Bool, String?)], extra: [(String, Data)] = []) async throws -> (ArchiveWriter, ArchiveReader, (String) throws -> Int64) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "unsub"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        var batch = mails.enumerated().map { n, m in
            (Self.mail(m.0, unsubscribe: m.1, post: m.2, auth: m.3),
             LocationInfo(account: "x", mailbox: m.0 == "junk" ? "Junk" : "INBOX", providerID: "\(n)"))
        }
        batch += extra.enumerated().map { n, e in (e.1, LocationInfo(account: "x", mailbox: e.0 == "sent" ? "Sent" : "INBOX", providerID: "e\(n)")) }
        _ = try await writer.ingest(batch)
        try AccountStore(layout: layout).save([AccountConfig.imap(id: "x", username: "u", host: "imap.own.test")])
        let r = try ArchiveReader(layout: layout)
        return (writer, r, { key in try #require(try r.messageIDs(MessageFilter(text: "msgid:\(key)@t.test ")).first) })
    }

    @Test func oneClickOnlyWhenSignedLockedWhenItLooksWrong() async throws {
        let (writer, r, id) = try await Self.archive([
            ("ok", "<https://esp.example/u?id=1>, <mailto:u@shop.example>", true, Self.signed),
            ("unsigned", "<https://esp.example/u?id=2>", true, "mail.own.test; dkim=none; dmarc=none"),
            ("mailonly", "<mailto:u@shop.example?subject=unsub>", false, Self.signed),
            ("ip", "<https://192.168.1.20/u>", true, Self.signed),
            ("phish", "<https://esp.example/u?id=3>", true, Self.signed),
            ("spam", "<https://esp.example/u?id=4>", true, Self.signed),
            ("junk", "<https://esp.example/u?id=5>", true, Self.signed),
            ("none", "<javascript:alert(1)>", false, Self.signed),
        ])
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

    @Test("Review 6.5c B1: a replayed signed mail with an unsubscribe header put on top is locked; unsigned headers get no one click")
    func replayAndSignatureCoverage() async throws {
        let replay = Self.mail("replay", unsubscribe: "<https://esp.example/u?id=1>", post: true, auth: Self.signed,
                               top: "List-Unsubscribe: <https://attacker.example/x>\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\n")
        let uncovered = Self.mail("uncovered", unsubscribe: "<https://esp.example/u?id=2>", post: true, auth: Self.signed,
                                  dkim: "DKIM-Signature: v=1; d=shop.example; s=s1; h=from:to:subject; bh=x; b=y\n")
        let foreignSigner = Self.mail("foreign", unsubscribe: "<https://esp.example/u?id=3>", post: true, auth: Self.signed,
                                      dkim: "DKIM-Signature: v=1; d=esp-other.example; s=s1; h=from:list-unsubscribe:list-unsubscribe-post; bh=x; b=y\n")
        // enough mail from the own server for it to count as own (a fifth, at least five)
        let (_, r, id) = try await Self.archive([("ok", "<https://esp.example/u?id=9>", true, Self.signed),
                                                 ("ok2", "<https://esp.example/u?id=8>", true, Self.signed),
                                                 ("ok3", "<https://esp.example/u?id=7>", true, Self.signed)],
                                                extra: [("replay", replay), ("uncovered", uncovered), ("foreign", foreignSigner)])
        #expect(try r.unsubscribeAssessment(for: try id("ok"))?.method == .oneClick(URL(string: "https://esp.example/u?id=9")!))
        let attacked = try #require(try r.unsubscribeAssessment(for: try id("replay")))
        #expect(attacked.isBlocked && attacked.blocked.first?.contains("mehr als eine Abmelde-Angabe") == true)
        #expect(attacked.method == .web(URL(string: "https://esp.example/u?id=1")!))  // the signed (bottom) one, never the one on top
        let notCovered = try #require(try r.unsubscribeAssessment(for: try id("uncovered")))
        #expect(notCovered.method == .web(URL(string: "https://esp.example/u?id=2")!) && notCovered.notes.contains { $0.contains("deckt die Abmelde-Angabe nicht") })
        #expect(try r.unsubscribeAssessment(for: try id("foreign"))?.method == .web(URL(string: "https://esp.example/u?id=3")!))  // not the From domain's signature
    }

    @Test("Review 6.5c S1, T3, T4: hosts that are no public name, foreign and failed checks, look-alikes")
    func hostsChecksAndLookAlikes() async throws {
        let foreign = "mx.other.example; dkim=pass header.d=shop.example; spf=pass; dmarc=pass header.from=shop.example"
        let failed = "mail.own.test; dkim=pass header.d=shop.example; spf=pass; dmarc=fail header.from=shop.example"
        let sent = Data("From: me@own.test\nTo: a@b.example\nSubject: Hallo\nMessage-ID: <sent@t.test>\n\nText\n".utf8)
        let lookalike = Self.mail("lookalike", unsubscribe: "<https://esp.example/u?id=7>", post: false, auth: Self.signed,
                                  from: "Musterbank <info@musterbank-service.example>")
        let (writer, r, id) = try await Self.archive([
            ("localhost", "<https://localhost/u>", true, Self.signed),
            ("decimal", "<https://2130706433/u>", true, Self.signed),
            ("hex", "<https://0x7f.0.0.1/u>", true, Self.signed),
            ("short", "<https://127.1/u>", true, Self.signed),
            ("mdns", "<https://printer.local/u>", true, Self.signed),
            ("percent", "<https://evil.example%40paypal.com/u>", true, Self.signed),
            ("own", "<https://grafana.own.test/u>", true, Self.signed),
            ("foreign", "<https://esp.example/u?id=5>", true, foreign),
            ("failed", "<https://esp.example/u?id=6>", true, failed),
        ], extra: [("sent", sent), ("lookalike", lookalike)])
        for key in ["localhost", "decimal", "hex", "short", "mdns", "percent", "own"] {
            #expect(try r.unsubscribeAssessment(for: try id(key))?.isBlocked == true, "\(key)")
        }
        #expect(try r.unsubscribeAssessment(for: try id("own"))?.blocked.first?.contains("deine eigene Domain own.test") == true)
        #expect(try r.unsubscribeAssessment(for: try id("foreign"))?.method == .web(URL(string: "https://esp.example/u?id=5")!))  // a foreign server's pass counts for nothing
        #expect(try r.unsubscribeAssessment(for: try id("failed"))?.blocked.contains { $0.contains("Prüfung deines Servers ist fehlgeschlagen") } == true)
        _ = try await writer.saveRelation(name: "Musterbank", domains: ["musterbank.example"], since: nil, until: nil)
        #expect(try r.unsubscribeAssessment(for: try id("lookalike"))?.blocked.contains { $0.contains("gibt sich als „Musterbank“ aus") } == true)
    }

    @Test("Review 6.5c S5: mailto keeps one address and the subject, nothing else")
    func mailtoIsRebuilt() {
        let tricky = UnsubscribeInfo.parse(listUnsubscribe: "<mailto:u@shop.example?subject=unsub&to=other@evil.example&body=hi%0D%0ABcc:x@y>", post: nil)
        #expect(tricky?.mailto?.absoluteString == "mailto:u@shop.example?subject=unsub")
        #expect(UnsubscribeInfo.parse(listUnsubscribe: "<mailto:u@shop.example?subject=a%0D%0ABcc:%20x@y.example>", post: nil)?.mailto?.absoluteString
                == "mailto:u@shop.example?subject=aBcc:%20x@y.example")  // the line break goes, the rest is only subject text
        for bad in ["<mailto:a@x.example,b@y.example>", "<mailto:a@x.example%0D%0ABcc:b@y.example>", "<mailto:nobody>", "<mailto:@x.example>"] {
            #expect(UnsubscribeInfo.parse(listUnsubscribe: bad, post: nil) == nil, "\(bad)")
        }
    }

    @Test func dkimSignatureCoverage() {
        var headers = HeaderList()
        headers.fields = [HeaderField(name: "DKIM-Signature", rawValue: "v=1; d=Shop.example; h=From : List-Unsubscribe:list-unsubscribe-post; b=abc=="),
                          HeaderField(name: "List-Unsubscribe", rawValue: "<https://esp.example/u>"),
                          HeaderField(name: "List-Unsubscribe-Post", rawValue: "List-Unsubscribe=One-Click")]
        #expect(DKIMSignature.covers(headers, fields: ["List-Unsubscribe", "List-Unsubscribe-Post"], domain: "news.shop.example"))
        #expect(!DKIMSignature.covers(headers, fields: ["List-Unsubscribe"], domain: "other.example"))
        headers.fields.insert(HeaderField(name: "List-Unsubscribe", rawValue: "<https://attacker.example/x>"), at: 0)
        #expect(!DKIMSignature.covers(headers, fields: ["List-Unsubscribe"], domain: "shop.example"))  // two instances, signed once
        #expect(DKIMSignature.parse("v=1; s=x") == nil)
    }

    @Test("Review 6.5c S1: only public addresses")
    func publicAddresses() async {
        #expect(!PublicHost.isPublic(v4: [127, 0, 0, 1]) && !PublicHost.isPublic(v4: [10, 0, 22, 36]) && !PublicHost.isPublic(v4: [192, 168, 1, 1]))
        #expect(!PublicHost.isPublic(v4: [172, 20, 0, 1]) && !PublicHost.isPublic(v4: [100, 100, 0, 1]) && !PublicHost.isPublic(v4: [169, 254, 1, 1]))
        #expect(!PublicHost.isPublic(v4: [0, 0, 0, 0]) && !PublicHost.isPublic(v4: [224, 0, 0, 1]) && PublicHost.isPublic(v4: [93, 184, 216, 34]))
        #expect(PublicHost.isPublic(v4: [172, 32, 0, 1]) && PublicHost.isPublic(v4: [100, 128, 0, 1]))
        let loopback6: [UInt8] = Array(repeating: 0, count: 15) + [1]
        let mapped: [UInt8] = Array(repeating: 0, count: 10) + [0xff, 0xff, 10, 0, 0, 1]
        #expect(!PublicHost.isPublic(v6: loopback6) && !PublicHost.isPublic(v6: mapped))
        #expect(!PublicHost.isPublic(v6: [0xfd] + Array(repeating: 0, count: 15)) && !PublicHost.isPublic(v6: [0xfe, 0x80] + Array(repeating: 0, count: 14)))
        #expect(PublicHost.isPublic(v6: [0x26, 0x06, 0x47, 0x00] + Array(repeating: 0, count: 12)))
        #expect(await PublicHost.resolvesPublicly("localhost") == false)  // /etc/hosts, no network needed
    }

    @Test("Review 6.5c T5: one click is a POST with the RFC 8058 body, no cookies, a plain user agent")
    func oneClickRequest() async throws {
        UnsubscribeStub.seen.withLock { $0 = [] }
        let status = try await OneClickUnsubscribe.post(URL(string: "https://esp.example/u?id=1")!, protocolClasses: [UnsubscribeStub.self])
        #expect(status == 200)
        let request = try #require(UnsubscribeStub.seen.withLock { $0.first })
        #expect(request.httpMethod == "POST" && request.httpBody == Data("List-Unsubscribe=One-Click".utf8))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "MailKeeper" && request.value(forHTTPHeaderField: "Cookie") == nil)
        await #expect(throws: URLError.self) { try await OneClickUnsubscribe.post(URL(string: "http://esp.example/u")!, protocolClasses: [UnsubscribeStub.self]) }
    }
}

/// Records the one-click request and answers 200.
final class UnsubscribeStub: URLProtocol, @unchecked Sendable {
    static let seen = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var r = request
        if r.httpBody == nil, let stream = r.httpBodyStream {
            stream.open()
            var data = Data(), buf = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
            r.httpBody = data
        }
        Self.seen.withLock { $0.append(r) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

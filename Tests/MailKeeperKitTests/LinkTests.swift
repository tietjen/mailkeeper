import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Links: Ziel und Köder (TJ, 5.6)")
struct LinkTests {
    @Test func targetsAndLures() {
        #expect(LinkCheck(href: "https://www.sparkasse.de/login", text: "Zum Online-Banking").findings.isEmpty)
        let lure = LinkCheck(href: "https://secure-login.evil.example/de", text: "https://www.sparkasse.de/login")
        #expect(lure.findings == [.textShowsOtherDomain] && lure.shownDomain == "sparkasse.de" && lure.domain == "evil.example")
        #expect(LinkCheck(href: "https://login.paypal.com/x", text: "www.paypal.com").findings.isEmpty)  // same registrable domain
        #expect(LinkCheck(href: "http://192.168.4.20/pay", text: "Jetzt bezahlen").findings == [.ipAddress])
        #expect(LinkCheck(href: "https://xn--pypal-4ve.com/", text: "PayPal").findings == [.punycode])
        #expect(LinkCheck(href: "https://bit.ly/3xYz", text: "Rechnung ansehen").findings == [.shortener])
        #expect(LinkCheck(href: "javascript:alert(1)", text: "klick").findings == [.unusualScheme])
        #expect(LinkCheck(href: "https://www.paypal.com@evil.example/", text: "PayPal").findings.contains(.credentialsInURL))
        #expect(LinkCheck(href: "https://shop.example.co.uk/x", text: "shop.example.co.uk").findings.isEmpty)
        #expect(LinkCheck(href: "mailto:info@firma.example", text: "info@andere.example").findings.isEmpty)
        #expect(LinkCheck(href: "https://cdn.example/a.pdf", text: "Rechnung.pdf").findings.isEmpty)  // a file name is no domain
    }

    @Test func linksFromHTMLAndText() {
        let html = #"<p>Hallo <a class="b" href="https://evil.example/x?a=1&amp;b=2">www.bank.example</a> und <A HREF='cid:logo'>Logo</A>, <a href=#top>oben</a></p>"#
        let links = LinkExtractor.links(html: html, text: "siehe https://info.example/agb und https://evil.example/x?a=1&b=2")
        #expect(links.map(\.href) == ["https://evil.example/x?a=1&b=2", "https://info.example/agb"])
        #expect(links.first?.text == "www.bank.example")
        let hostile = String(repeating: "<a href=\"x", count: 20_000) + String(repeating: "<a href=x>", count: 20_000)
        let t = ContinuousClock().measure { _ = LinkExtractor.links(html: hostile, text: "") }
        #expect(t < .seconds(2))
    }
}

import Foundation
import Testing
@testable import MailKeeperKit

/// Synthetic messages only — this repository is public.
func eml(_ s: String) -> Data {
    Data(s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
}

@Suite("MIME parser")
struct MIMEParserTests {
    @Test func plainQuotedPrintableWithEncodedSubject() {
        let p = MIMEParser.parse(eml("""
        From: "Probe, Max" <Max.Probe@Example.TEST>
        To: a@example.test, "B" <b@example.test>
        Subject: =?UTF-8?Q?Gr=C3=BC=C3=9Fe?= =?UTF-8?Q?_aus_der?= Probe
        Date: Thu, 14 Mar 2019 10:00:00 +0100
        Message-ID: <abc-1@example.test>
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Umlaute: =C3=A4=C3=B6=C3=BC, lange Zeile mit weichem =
        Umbruch.
        """))
        #expect(p.subject == "Grüße aus der Probe")
        #expect(p.from == [MailAddress(name: "Probe, Max", address: "max.probe@example.test")])
        #expect(p.to.map(\.address) == ["a@example.test", "b@example.test"])
        #expect(p.messageID == "<abc-1@example.test>")
        #expect(p.date == Date(timeIntervalSince1970: 1_552_554_000))
        #expect(p.text.contains("Umlaute: äöü, lange Zeile mit weichem Umbruch."))
        #expect(p.attachments.isEmpty)
    }

    @Test func alternativePrefersPlainForTextAndKeepsHTML() {
        let p = MIMEParser.parse(eml("""
        From: s@example.test
        Subject: alt
        Content-Type: multipart/alternative; boundary="b1"

        preamble
        --b1
        Content-Type: text/plain; charset=utf-8

        Plain body
        --b1
        Content-Type: text/html; charset=utf-8

        <p>HTML <b>body</b> &amp; more</p>
        --b1--
        epilogue
        """))
        #expect(p.text == "Plain body")
        #expect(p.html?.contains("<b>body</b>") == true)
    }

    @Test func htmlOnlyIsConvertedToText() {
        let p = MIMEParser.parse(eml("""
        Content-Type: text/html; charset=utf-8

        <html><head><title>T</title><style>p{color:red}</style></head><body>
        <script>alert(1)</script><p>Erste&nbsp;Zeile</p><div>Zweite &euro; &#x263A; &#228;</div>
        <!-- hidden --><table><tr><td>a</td><td>b</td></tr></table></body></html>
        """))
        #expect(p.text == "Erste Zeile\n\nZweite € ☺ ä\n\na b")
    }

    @Test func mixedRelatedWithRFC2231FilenameAndInlineImage() {
        let p = MIMEParser.parse(eml("""
        Content-Type: multipart/mixed; boundary=outer

        --outer
        Content-Type: multipart/related; boundary="rel"

        --rel
        Content-Type: text/html; charset=utf-8

        <p>Bild: <img src="cid:img1@x"></p>
        --rel
        Content-Type: image/png
        Content-ID: <img1@x>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --rel--
        --outer
        Content-Type: application/pdf
        Content-Disposition: attachment;
         filename*0*=utf-8''Rechnung%20M%C3%A4rz;
         filename*1*=%202019.pdf
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --outer--
        """))
        #expect(p.text == "Bild:")
        let pdf = p.attachments.first { $0.mimeType == "application/pdf" }
        #expect(pdf?.filename == "Rechnung März 2019.pdf")
        #expect(pdf?.size == 9)
        #expect(pdf?.isInline == false)
        let img = p.attachments.first { $0.mimeType == "image/png" }
        #expect(img?.contentID == "<img1@x>")
        #expect(img?.isInline == true)
    }

    @Test("Embedded only when the HTML shows it: Apple Mail inline PDFs, Outlook CIDs")
    func embeddedVersusAttached() {
        let p = MIMEParser.parse(eml("""
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: multipart/related; boundary=r

        --r
        Content-Type: text/html

        <img src=CID:logo%40firma.de> <a href="cid:vertrag">PDF</a>
        --r
        Content-Type: image/png
        Content-ID: <Logo@firma.de>

        x
        --r
        Content-Type: application/pdf
        Content-ID: <vertrag>
        Content-Disposition: inline; filename=vertrag.pdf

        y
        --r--
        --m
        Content-Type: application/pdf
        Content-Disposition: inline; filename="Rechnung.pdf"

        z
        --m
        Content-Type: image/jpeg
        Content-ID: <foto@iphone>
        Content-Disposition: inline; filename=IMG_0001.jpg

        w
        --m
        Content-Type: application/zip
        Content-ID: <outlook-att@x>
        Content-Disposition: attachment; filename=daten.zip

        v
        --m--
        """))
        let byName = Dictionary(uniqueKeysWithValues: p.attachments.map { ($0.filename ?? $0.mimeType, $0.isInline) })
        #expect(byName["image/png"] == true)        // referenced (case and %-encoding differ)
        #expect(byName["vertrag.pdf"] == false)     // referenced, but documents always show
        #expect(byName["Rechnung.pdf"] == false)    // Apple Mail: inline disposition, no cid
        #expect(byName["IMG_0001.jpg"] == false)    // cid, but no HTML shows it
        #expect(byName["daten.zip"] == false)       // Outlook puts CIDs on every file
    }

    @Test func latin1BodyAndBEncodedSubject() {
        var d = eml("""
        Subject: =?ISO-8859-1?B?R3L832UgYXVzIGRlbSBBcmNoaXY=?=
        Content-Type: text/plain; charset=iso-8859-1
        Content-Transfer-Encoding: 8bit


        """)
        d.append(contentsOf: [0x47, 0x72, 0xFC, 0xDF, 0x65, 0x20, 0x80])  // "Grüße €" in Windows-1252
        let p = MIMEParser.parse(d)
        #expect(p.subject == "Grüße aus dem Archiv")
        #expect(p.text == "Grüße €")
    }

    @Test func eightBitHeadersAndEncodedFilenameInQuotes() {
        let p = MIMEParser.parse(eml("""
        Subject: Übernahme ohne Kodierung
        Content-Type: multipart/mixed; boundary=x

        --x
        Content-Type: text/plain

        hi
        --x
        Content-Type: application/octet-stream; name="=?UTF-8?B?w4RyZ2VyLnR4dA==?="
        Content-Disposition: attachment

        data
        --x--
        """))
        #expect(p.subject == "Übernahme ohne Kodierung")
        #expect(p.attachments.first?.filename == "Ärger.txt")
    }

    @Test func malformedInputNeverCrashes() {
        let samples: [Data] = [
            Data(),
            Data("no headers at all".utf8),
            eml("Content-Type: multipart/mixed; boundary=\"zz\"\n\n--zz\nContent-Type: text/plain\n\nunterminated"),
            eml("Content-Type: multipart/mixed\n\nno boundary parameter"),
            eml("Content-Type: text/plain\nContent-Transfer-Encoding: base64\n\n!!!not base64 at all===="),
            eml("Subject: =?utf-8?Q?broken\n\nbody"),
            eml("Content-Type: garbage\n\nbody"),
            Data(repeating: 0xFF, count: 4096),
        ]
        for s in samples { _ = MIMEParser.parse(s) }
        #expect(MIMEParser.parse(samples[2]).text == "unterminated")
        #expect(MIMEParser.parse(samples[6]).text == "body")
    }

    @Test func deepNestingIsCapped() {
        var body = "inner\n"
        for level in 0..<40 {
            body = "Content-Type: multipart/mixed; boundary=b\(level)\n\n--b\(level)\n\(body)--b\(level)--\n"
        }
        let p = MIMEParser.parse(eml(body))
        #expect(p.truncated)
    }

    @Test func forwardedMessageIsAnAttachment() {
        let p = MIMEParser.parse(eml("""
        Content-Type: multipart/mixed; boundary=f

        --f
        Content-Type: text/plain

        siehe unten
        --f
        Content-Type: message/rfc822

        Subject: Original
        From: o@example.test

        original body
        --f--
        """))
        #expect(p.text == "siehe unten")
        #expect(p.attachments.first?.filename == "Original.eml")
    }

    @Test func listHeaders() {
        let p = MIMEParser.parse(eml("""
        List-Id: Probe Newsletter <News.Example.Test>
        List-Unsubscribe: <mailto:u@example.test>
        Precedence: Bulk
        Auto-Submitted: auto-generated

        x
        """))
        #expect(p.listID == "news.example.test")
        #expect(p.hasListUnsubscribe)
        #expect(p.precedence == "bulk")
        #expect(p.autoSubmitted == "auto-generated")
    }
}

@Suite("Header pieces")
struct HeaderPieceTests {
    @Test func addresses() {
        let list = AddressParser.parse(#"""
        "Doe, Jane" <JANE@example.test>, team: a@example.test, (Kommentar) b@example.test;,
        =?UTF-8?Q?J=C3=BCrgen?= <j@example.test>, plain@example.test (Plain Name), <@route.test:r@example.test>,
        "Quote \" inside" <q@example.test>, "<odd,name>" <odd@example.test>
        """#)
        #expect(list.map(\.address) == ["jane@example.test", "a@example.test", "b@example.test", "j@example.test",
                                        "plain@example.test", "r@example.test", "q@example.test", "odd@example.test"])
        #expect(list[0].name == "Doe, Jane")
        #expect(list[3].name == "Jürgen")
        #expect(list[4].name == "Plain Name")
        #expect(list[6].name == "Quote \" inside")
        #expect(list[7].name == "<odd,name>")
    }

    @Test(arguments: [
        ("Thu, 14 Mar 2019 10:00:00 +0100", 1_552_554_000.0),
        ("14 Mar 2019 10:00:00 +0100", 1_552_554_000),
        ("Thu, 14 Mar 2019 09:00:00 GMT", 1_552_554_000),
        ("Thu, 14 Mar 19 04:00:00 EST", 1_552_554_000),
        ("Thu, 14 Mar 2019 10:00 +0100 (CET)", 1_552_554_000),
        ("Thu Mar 14 09:00:00 2019", 1_552_554_000),
        ("2019-03-14T09:00:00Z", 1_552_554_000),
        ("Do, 14 Mär 2019 10:00:00 +0100", 1_552_554_000),
    ])
    func dates(raw: String, epoch: Double) {
        #expect(MailDate.parse(raw)?.timeIntervalSince1970 == epoch)
    }

    @Test func invalidDates() {
        #expect(MailDate.parse("yesterday") == nil)
        #expect(MailDate.parse("32 Mar 2019 10:00:00") == nil)
        #expect(MailDate.parse(nil) == nil)
    }

    @Test func encodedWordsSpacing() {
        #expect(EncodedWords.decode("=?utf-8?q?a?= =?utf-8?q?b?=") == "ab")
        #expect(EncodedWords.decode("x =?utf-8?q?a?= y") == "x a y")
        #expect(EncodedWords.decode("=?utf-8?q?a b?=") == "=?utf-8?q?a b?=")  // spaces make it invalid
        #expect(EncodedWords.decode("=?utf-8*de?Q?Gr=C3=BC=C3=9Fe?=") == "Grüße")
    }

    @Test func quotedPrintableAndBase64Tolerance() {
        #expect(String(decoding: TransferEncoding.quotedPrintable(Data("a=3Db=\r\nc= \r\nd=ZZ".utf8)), as: UTF8.self) == "a=bcd=ZZ")
        #expect(String(decoding: TransferEncoding.base64(Data("SGFs\r\nbG8".utf8)), as: UTF8.self) == "Hallo")
    }

    @Test func searchQuery() {
        #expect(SearchText.ftsQuery("Grüße") == #"("Grüsse"* OR "gruesse"*)"#)
        #expect(SearchText.ftsQuery("mueller rechnung ") == #"("mueller" OR "müller") AND "rechnung""#)
        #expect(SearchText.ftsQuery("\"\" ;") == nil)
        #expect(SearchText.ftsQuery("a\"b") == #""ab"*"#)
    }
}

@Suite("Attachments")
struct AttachmentTests {
    @Test func extractsBytesByPartPath() {
        let p = MIMEParser.parse(eml("""
        Content-Type: multipart/mixed; boundary=o

        --o
        Content-Type: multipart/alternative; boundary=a

        --a
        Content-Type: text/plain

        hi
        --a--
        --o
        Content-Type: application/pdf; name="r.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --o
        Content-Type: text/plain; name="notiz.txt"
        Content-Disposition: attachment

        Notiz
        --o--
        """))
        #expect(p.attachments.map(\.partPath) == [[1], [2]])
        #expect(p.data(of: p.attachments[0]) == Data("%PDF-1.4\n".utf8))
        #expect(p.data(of: p.attachments[1]) == Data("Notiz".utf8))
        #expect(p.data(of: AttachmentInfo(filename: nil, mimeType: "x/y", size: 0, contentID: nil, isInline: false, partPath: [9])) == nil)
    }

    @Test(arguments: [
        ("rechnung\u{202E}fdp.exe", "application/octet-stream", "rechnungfdp.exe"),
        ("../../.ssh/authorized_keys", "text/plain", "authorized_keys.txt"),
        ("C:\\Users\\x\\evil.bat", "application/octet-stream", "evil.bat"),
        ("..hidden", "text/plain", "hidden.txt"),
        ("a\u{0000}b\u{001B}[31mc.txt", "text/plain", "ab[31mc.txt"),
        ("zero\u{200B}width.pdf", "application/pdf", "zerowidth.pdf"),
        ("Rechnung", "application/pdf", "Rechnung.pdf"),
        ("", "image/png", "Anhang.png"),
        ("Bericht: März.pdf", "application/pdf", "Bericht_ März.pdf"),
    ])
    func sanitizedNames(raw: String, mime: String, expected: String) {
        #expect(AttachmentSafety.sanitizedFilename(raw, mimeType: mime) == expected)
    }

    @Test func longNamesKeepTheirExtensionAndFitTheFileSystem() throws {
        let ascii = AttachmentSafety.sanitizedFilename(String(repeating: "x", count: 500) + ".pdf", mimeType: "application/pdf")
        #expect(ascii.utf8.count <= AttachmentSafety.maxNameBytes && ascii.hasSuffix(".pdf"))
        for long in [String(repeating: "ä", count: 300), String(repeating: "請", count: 200), String(repeating: "😀", count: 100)] {
            let name = AttachmentSafety.sanitizedFilename(long + ".pdf", mimeType: "application/pdf")
            #expect(name.utf8.count <= AttachmentSafety.maxNameBytes && name.hasSuffix(".pdf"))
            try AttachmentSafety.writeQuarantined(Data("x".utf8), to: tempDir().appending(path: name))  // must be writable
        }
    }

    @Test(arguments: [
        ("rechnung.pdf\u{2028}.exe", "rechnung.pdf.exe", "rechnung.pdf .exe"),
        ("rechnung.pdf" + String(repeating: "\u{00A0}", count: 60) + ".docm", "rechnung.pdf.docm", "rechnung.pdf .docm"),
        ("a\u{3164}\u{2800}b\u{E000}c\u{0378}.txt", "a bc.txt", "a bc.txt"),
    ])
    func invisiblePaddingIsCollapsed(raw: String, file: String, display: String) {
        // The real extension always ends up visible; nothing hides behind invisible padding.
        #expect(AttachmentSafety.sanitizedFilename(raw, mimeType: "application/octet-stream") == file)
        #expect(DisplayText.safe(raw) == display)
    }

    @Test func webContentIsRiskyAndPreviewedAsText() {
        for name in ["phish.html", "x.htm", "x.svg", "x.webarchive", "x.mhtml", "link.url", "x.webloc",
                     "profile.mobileconfig", "a.shortcut", "b.wflow"] {
            #expect(AttachmentSafety.isRisky(filename: name, mimeType: "application/octet-stream"), "\(name)")
        }
        #expect(AttachmentSafety.isWebContent(filename: "phish.html", mimeType: "text/html"))
        #expect(AttachmentSafety.isWebContent(filename: "anhang", mimeType: "text/html"))
        #expect(!AttachmentSafety.isWebContent(filename: "Rechnung.pdf", mimeType: "application/pdf"))
        #expect(AttachmentSafety.textPreview(Data("<b>\u{202E}hi\u{0007}</b>\n".utf8)) == "<b>hi</b>\n")
    }

    @Test func writtenAttachmentsAreQuarantinedAndPrivate() throws {
        let url = tempDir().appending(path: "tool.command")
        try AttachmentSafety.writeQuarantined(Data("#!/bin/sh\necho hi\n".utf8), to: url)
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        #expect(size > 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1) + 1)
        _ = getxattr(url.path, "com.apple.quarantine", &buffer, size, 0, 0)
        // "<flags>;<time>;<agent>;<uuid>" — the agent name is filled from the calling app's
        // bundle (empty for the test runner); what matters is an active quarantine flag.
        let fields = String(cString: buffer).split(separator: ";", omittingEmptySubsequences: false)
        #expect(fields.count >= 4)
        #expect(UInt32(fields.first ?? "", radix: 16).map { $0 & 0x1 != 0 } == true)
        #expect(posixMode(url) == 0o600)
    }

    @Test func displayTextDropsBidiControls() {
        #expect(DisplayText.safe("rechnung\u{202E}fdp.exe") == "rechnungfdp.exe")
        #expect(DisplayText.safe("a\u{2066}b\u{2069}c") == "abc")
        #expect(DisplayText.safe("Familie 👨\u{200D}👩\u{200D}👧") == "Familie 👨\u{200D}👩\u{200D}👧")  // ZWJ kept
    }

    @Test func uniqueWritesNeverOverwrite() throws {
        let dir = tempDir()
        try Data("A".utf8).write(to: dir.appending(path: "a.pdf"))
        try Data("B".utf8).write(to: dir.appending(path: "a 2.pdf"))
        let url = try AttachmentSafety.writeQuarantinedUnique(Data("C".utf8), in: dir, name: "a.pdf")
        #expect(url.lastPathComponent == "a 3.pdf")
        #expect(try Data(contentsOf: dir.appending(path: "a.pdf")) == Data("A".utf8))
        #expect(throws: (any Error).self) {
            try AttachmentSafety.writeQuarantined(Data("D".utf8), to: dir.appending(path: "a.pdf"), replace: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }.isEmpty)
    }
}

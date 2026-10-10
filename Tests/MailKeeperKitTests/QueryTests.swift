import Foundation
import Testing
@testable import MailKeeperKit

private let berlin: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private let now = day(2026, 10, 10, 12)

private func parse(_ s: String) throws -> QueryNode? {
    try QueryParser.parse(s, now: now, calendar: berlin).root
}

private func text(_ v: String, _ f: QueryPredicate.TextField = .any, prefix: Bool = false) -> QueryNode {
    .predicate(.text(f, v, prefix: prefix))
}

@Suite("Query language (ADR-0008)")
struct QueryParserTests {
    @Test func wordsPhrasesAndLivePrefix() throws {
        #expect(try parse("rechnung amaz") == .and([text("rechnung"), text("amaz", prefix: true)]))
        #expect(try parse("rechnung amaz ") == .and([text("rechnung"), text("amaz")]))
        #expect(try parse("\"jahres abrechnung\"") == text("jahres abrechnung"))
        #expect(try parse("rech* x") == .and([text("rech", prefix: true), text("x", prefix: true)]))
        #expect(try parse("Grüße ") == text("Grüsse"))
        #expect(try parse("& ; -") == nil)  // punctuation alone (a dash with nothing after it, too): no condition
        #expect(try parse("") == nil)
    }

    @Test func fieldsAndGermanAliases() throws {
        #expect(try parse("von:Müller betreff:\"Jahres Abrechnung\" an:max ") == .and([
            text("Müller", .from), text("Jahres Abrechnung", .subject), text("max", .to),
        ]))
        #expect(try parse("FROM:x hat:pdf ist:ungelesen konto:Gmail ordner:INBOX ") == .and([
            text("x", .from), .predicate(.has(.pdf)), .predicate(.flag(.unread)), .predicate(.account("gmail")),
            .predicate(.folder("INBOX", prefix: false)),
        ]))
        #expect(try parse("folder:Archiv/* sender:Billing@Amazon.de msgid:abc@x") == .and([
            .predicate(.folder("Archiv/", prefix: true)), .predicate(.sender("billing@amazon.de")),
            .predicate(.messageID("<abc@x>")),
        ]))
        #expect(try parse("on:server only:archiv is:list label:Steuer") == .and([
            .predicate(.onServer), .predicate(.archiveOnly), .predicate(.isList), .predicate(.label("steuer")),
        ]))
    }

    @Test func unknownWordsBeforeAColonStayText() throws {
        #expect(try parse("https://x.de re:hallo ") == .and([text("https://x.de"), text("re:hallo")]))
    }

    @Test func negationOrAndGrouping() throws {
        #expect(try parse("a b OR c ") == .or([.and([text("a"), text("b")]), text("c")]))
        #expect(try parse("-from:x (a OR b) ") == .and([.not(text("x", .from)), .or([text("a"), text("b")])]))
        #expect(try parse("NOT a AND b ") == .and([.not(text("a")), text("b")]))
        #expect(try parse("e-mail ") == text("e-mail"))
        #expect(try parse("-(a b) ") == .not(.and([text("a"), text("b")])))
    }

    @Test func invalidValuesFailInsteadOfWidening() {
        for bad in ["larger:abc", "before:2024-02-30", "after:13.13.2024", "is:foo", "has:video", "from:", "from:\"\"",
                    "(a", "a)", "a OR", "OR a", "a OR OR b", "- )", "()", "date:30d", "on:moon", "folder:*",
                    String(repeating: "a ", count: 65), String(repeating: "(", count: 17) + "a" + String(repeating: ")", count: 17),
                    String(repeating: "x", count: 4_097)] {
            #expect(throws: QueryError.self, "\(bad.prefix(40))") { _ = try parse(bad) }
        }
    }

    @Test func calendarPeriodsInLocalTime() throws {
        #expect(try parse("after:2024-03") == .predicate(.dateFrom(day(2024, 3, 1))))
        #expect(try parse("ab:2024") == .predicate(.dateFrom(day(2024, 1, 1))))
        #expect(try parse("before:2025") == .predicate(.dateBefore(day(2025, 1, 1))))
        #expect(try parse("vor:17.3.2024") == .predicate(.dateBefore(day(2024, 3, 17))))
        #expect(try parse("until:2024-12-31") == .predicate(.dateBefore(day(2025, 1, 1))))
        #expect(try parse("bis:2024-02") == .predicate(.dateBefore(day(2024, 3, 1))))
        #expect(try parse("date:2024-05") == .and([.predicate(.dateFrom(day(2024, 5, 1))), .predicate(.dateBefore(day(2024, 6, 1)))]))
        #expect(try parse("datum:2024/02/29") == .and([.predicate(.dateFrom(day(2024, 2, 29))), .predicate(.dateBefore(day(2024, 3, 1)))]))
        #expect(try parse("date:heute") == .and([.predicate(.dateFrom(day(2026, 10, 10))), .predicate(.dateBefore(day(2026, 10, 11)))]))
        #expect(try parse("after:30d") == .predicate(.dateFrom(berlin.date(byAdding: .day, value: -30, to: now)!)))
        #expect(try parse("before:1j") == .predicate(.dateBefore(day(2025, 10, 10, 12))))
    }

    @Test func sizes() {
        #expect(QueryParser.size("500") == 500)
        #expect(QueryParser.size("5M") == 5 << 20)
        #expect(QueryParser.size("1,5k") == 1_536)
        #expect(QueryParser.size("2 MB") == 2 << 20)
        #expect(QueryParser.size("1GiB") == 1 << 30)
        for bad in ["", "M", "1x", "1.2.3", "-5", "0x10", "inf", "1e9"] { #expect(QueryParser.size(bad) == nil, "\(bad)") }
    }

    @Test func chipsNameEachTopLevelTermAndItsRange() throws {
        let q = "from:amazon has:pdf -is:read \"jahres abrechnung\""
        let chips = try QueryParser.parse(q, now: now, calendar: berlin).chips
        #expect(chips.map(\.label) == ["Von: amazon", "mit PDF", "nicht gelesen", "„jahres abrechnung“"])
        #expect(chips.map { String(q[$0.range]) } == ["from:amazon", "has:pdf", "-is:read", "\"jahres abrechnung\""])
        #expect(try QueryParser.parse("a OR b", now: now, calendar: berlin).chips.map(\.label) == ["a OR b"])
    }

    @Test func ftsExpressionsAreQuotedWithVariants() {
        #expect(QuerySQL.fts(.any, "Grüsse", prefix: true) == #"("Grüsse"* OR "gruesse"*)"#)
        #expect(QuerySQL.fts(.from, "mueller", prefix: false) == #"from_text : ("mueller" OR "müller")"#)
        #expect(QuerySQL.fts(.subject, "a b", prefix: false) == #"subject : "a b""#)
        #expect(QuerySQL.escapeLike(#"50%_\x"#) == #"50\%\_\\x"#)
    }
}

@Suite("Query language against an archive")
struct QueryArchiveTests {
    /// m1 Amazon invoice (Apple Mail inline PDF), m2 newsletter, m3 Müller (big, flagged, archive
    /// only, label), m4 invitation with image.
    static func archive() async throws -> ArchiveReader {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "q"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "a", kind: "imap", name: "A"))
        try await writer.register(AccountInfo(id: "b", kind: "imap", name: "B"))
        let m1 = eml("""
        From: Amazon <billing@amazon.de>
        To: jan@example.test
        Subject: Ihre Rechnung
        Date: Sun, 10 Mar 2024 10:00:00 +0100
        Message-ID: <m1@test>
        Content-Type: multipart/mixed; boundary=b

        --b
        Content-Type: text/plain

        Danke für Ihre Bestellung.
        --b
        Content-Type: application/pdf
        Content-Disposition: inline; filename=Rechnung-2024.pdf

        %PDF
        --b--
        """)
        let m2 = eml("""
        From: News <news@example.com>
        Subject: Wochenrückblick
        Date: Thu, 01 Jun 2023 08:00:00 +0200
        Message-ID: <m2@test>
        List-Id: Weekly <news.example.com>
        List-Unsubscribe: <mailto:unsub@example.com>

        Neuigkeiten
        """)
        let m3 = eml("""
        From: Hans Müller <mueller@firma.de>
        Subject: Jahresabrechnung 2024
        Date: Wed, 15 Jan 2025 09:00:00 +0100
        Message-ID: <m3@test>

        Anbei der Vertrag. \(String(repeating: "x", count: 20_000))
        """)
        let m4 = eml("""
        From: Kalender <cal@example.org>
        Subject: Einladung Silvester
        Date: Tue, 31 Dec 2024 23:30:00 +0100
        Message-ID: <m4@test>
        Content-Type: multipart/mixed; boundary=c

        --c
        Content-Type: text/plain

        Feier
        --c
        Content-Type: text/calendar; method=REQUEST

        BEGIN:VCALENDAR
        --c
        Content-Type: image/jpeg
        Content-Disposition: attachment; filename=karte.jpg

        jpg
        --c--
        """)
        _ = try await writer.ingest([
            (m1, LocationInfo(account: "a", mailbox: "INBOX", uidValidity: 1, uid: 1, flags: ["\\Seen"])),
            (m2, LocationInfo(account: "a", mailbox: "Newsletter", uidValidity: 1, uid: 2)),
            (m3, LocationInfo(account: "b", mailbox: "Archiv/2025", uidValidity: 1, uid: 3, flags: ["\\Flagged"], labels: ["Steuer"])),
            (m4, LocationInfo(account: "a", mailbox: "INBOX", uidValidity: 1, uid: 4)),
        ])
        _ = try await writer.markGone(account: "b", mailbox: "Archiv/2025", uidValidity: 1, uids: [3])
        return try ArchiveReader(layout: layout)
    }

    static func subjects(_ reader: ArchiveReader, _ query: String) throws -> Set<String> {
        let ids = try reader.messageIDs(MessageFilter(text: query + " ", now: now))
        return Set(try reader.summaries(ids).compactMap(\.subject))
    }

    @Test func everyFieldSelectsTheRightMessages() async throws {
        let r = try await Self.archive()
        let (m1, m2, m3, m4) = ("Ihre Rechnung", "Wochenrückblick", "Jahresabrechnung 2024", "Einladung Silvester")
        let cases: [(String, Set<String>)] = [
            ("rechnung", [m1]),
            ("from:amazon", [m1]), ("sender:billing@amazon.de", [m1]), ("sender:amazon.de", []),
            ("von:mueller", [m3]), ("from:müller", [m3]), ("subject:jahresabrechnung", [m3]), ("body:vertrag", [m3]),
            ("has:pdf", [m1]), ("has:attachment", [m1, m4]), ("has:image", [m4]), ("has:calendar", [m4]),
            ("filename:rechnung", [m1]),
            ("after:2024 before:2025", [m1, m4]), ("date:2024-03", [m1]), ("until:2024-12-31 after:2024-12", [m4]),
            ("before:2024", [m2]), ("after:2025", [m3]),
            ("larger:10K", [m3]), ("smaller:10K", [m1, m2, m4]),
            ("account:b", [m3]), ("folder:inbox", [m1, m4]), ("folder:Archiv/*", [m3]), ("folder:Archiv", []),
            ("label:steuer", [m3]), ("list:news.example", [m2]), ("is:list", [m2]),
            ("is:read", [m1]), ("is:unread", [m2, m3, m4]), ("is:flagged", [m3]),
            ("only:archive", [m3]), ("on:server", [m1, m2, m4]), ("msgid:m1@test", [m1]),
            ("rechnung OR is:flagged", [m1, m3]), ("-from:amazon has:attachment", [m4]),
            ("(from:amazon OR from:mueller) -has:pdf", [m3]), ("-rechnung -is:list", [m3, m4]),
        ]
        for (query, expected) in cases {
            #expect(try Self.subjects(r, query) == expected, "\(query)")
        }
    }

    @Test func valuesCannotInjectSQLOrPatterns() async throws {
        let r = try await Self.archive()
        #expect(try Self.subjects(r, "\"'); DROP TABLE messages; --\"").isEmpty)
        #expect(try Self.subjects(r, "folder:%").isEmpty)
        #expect(try Self.subjects(r, "folder:_NBOX").isEmpty)
        #expect(try Self.subjects(r, "list:%").isEmpty)
        #expect(try Self.subjects(r, "subject:\"x\" OR \"y\"").isEmpty)
        #expect(try r.stats().messages == 4)
        #expect(throws: QueryError.self) { _ = try r.messageIDs(MessageFilter(text: "larger:abc")) }
    }
}

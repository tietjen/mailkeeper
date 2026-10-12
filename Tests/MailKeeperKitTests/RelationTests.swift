import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Beziehungsregister (6.3)")
struct RelationTests {
    @Test func authenticationResultsAreReadLikeTheRFCSays() {
        let r = AuthResults.parse("""
            mail.own.test; dkim=pass (2048-bit key; unprotected) header.d=bank.example header.s=k1 header.b=abc;
             dkim=fail header.d=other.example; spf=pass (mail.own.test: domain of x@bank.example designates 1.2.3.4) smtp.mailfrom=bank.example;
             dmarc=pass (policy=reject) header.from=bank.example
            """)
        #expect(r == AuthResults(server: "mail.own.test", dkim: "pass", spf: "pass", dmarc: "pass", fromDomain: "bank.example"))
        #expect(r?.summary == "dkim=pass spf=pass dmarc=pass")
        #expect(AuthResults.parse("mx.google.com;\n       arc=pass; dmarc=fail header.from=bank.example")?.dmarc == "fail")
        #expect(AuthResults.parse("i=1; mx.google.com; dkim=pass")?.server == nil)  // no authserv-id first: none claimed
        #expect(AuthResults.parse("") == nil && AuthResults.parse(nil) == nil && AuthResults.parse("mail.own.test; none") != nil)
        let headers = HeaderParser.parse(Data("Delivered-To: Kontakt@Firma.test\nX-Original-To: alias@firma.test\nSubject: x\n\n".utf8)).0
        #expect(DeliveredTo.address(headers) == "kontakt@firma.test")
    }

    static func mail(_ id: String, from: String, to: String = "me@own.test", subject: String, auth: String? = nil, date: String = "14 Mar 2024") -> Data {
        var s = "From: \(from)\nTo: \(to)\nSubject: \(subject)\nDate: Thu, \(date) 10:00:00 +0100\nMessage-ID: <\(id)@t.test>\n"
        if let auth { s = "Authentication-Results: \(auth)\n" + s }
        return Data((s + "\nText\n").utf8)
    }

    static func archive() async throws -> (ArchiveLayout, ArchiveWriter, ArchiveReader) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "rel"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let pass = { (d: String) in "mail.own.test; dkim=pass header.d=\(d); spf=pass; dmarc=pass header.from=\(d)" }
        var batch: [(data: Data, location: LocationInfo)] = []
        func add(_ d: Data, _ box: String = "INBOX") { batch.append((d, LocationInfo(account: "x", mailbox: box, providerID: "\(batch.count)"))) }
        // a bank with authenticated statements, from two domains under one name
        add(mail("b1", from: "Sparkasse <info@sparkasse.example>", subject: "Kontoauszug", auth: pass("sparkasse.example"), date: "14 Mar 2019"))
        add(mail("b2", from: "Sparkasse <info@sparkasse.example>", subject: "Kontoauszug", auth: pass("sparkasse.example")))
        add(mail("b3", from: "Sparkasse <noreply@s-online.example>", subject: "Kontoauszug", auth: pass("s-online.example")))
        add(mail("b4", from: "Sparkasse <noreply@s-online.example>", subject: "Kontoauszug", auth: pass("s-online.example")))
        // a craftsman the user wrote to
        add(mail("h1", from: "Max <max@handwerk.example>", subject: "Angebot", auth: pass("handwerk.example")))
        add(mail("s1", from: "me@own.test", to: "max@handwerk.example, freund@gmail.com", subject: "Re: Angebot"), "Sent")
        // a friend on freemail, a newsletter without evidence, a spammer the user answered once
        add(mail("f1", from: "freund@gmail.com", subject: "Grillen", auth: pass("gmail.com")))
        add(mail("n1", from: "news@shop.example", subject: "Sale", auth: pass("shop.example")))
        add(mail("x1", from: "win@lotto.example", subject: "Gewinn", auth: pass("lotto.example")))
        add(mail("x2", from: "win@lotto.example", subject: "Gewinn", auth: pass("lotto.example")))
        add(mail("s2", from: "me@own.test", to: "win@lotto.example", subject: "Stop"), "Sent")
        // a forged header: another server's results in a mail of this account
        add(mail("z1", from: "info@sparkasse.example", subject: "Konto gesperrt", auth: "evil.example; dmarc=pass header.from=sparkasse.example"))
        _ = try await writer.ingest(batch)
        // the account's IMAP host shares the own server's domain (review 6 B1: host or majority)
        try AccountStore(layout: layout).save([AccountConfig.imap(id: "x", username: "u", host: "imap.own.test")])
        let r = try ArchiveReader(layout: layout)
        let id = { (key: String) in try #require(try r.messageIDs(MessageFilter(text: "msgid:\(key)@t.test ")).first) }
        for key in ["b1", "b2", "b3", "b4"] { try await writer.setClassification(messageID: try id(key), category: .invoice, source: .heuristic, model: nil, reason: nil) }
        for key in ["x1", "x2"] { try await writer.setUserClassification(identity: try #require(try r.identities(of: [try id(key)]).first), category: .spam) }
        return (layout, writer, r)
    }

    @Test func theOwnServerIsLearnedAndOnlyItsResultsCount() async throws {
        let (_, _, r) = try await Self.archive()
        #expect(try r.ownAuthServers() == ["x": ["mail.own.test"]])
        let real = try #require(try r.messageIDs(MessageFilter(text: "msgid:b1@t.test ")).first)
        let forged = try #require(try r.messageIDs(MessageFilter(text: "msgid:z1@t.test ")).first)
        #expect(try r.authentication(of: real)?.trusted == true && r.authentication(of: real)?.results.dmarc == "pass")
        #expect(try r.authentication(of: forged)?.trusted == false)  // dmarc=pass, but not from the own server
    }

    @Test func suggestionsNeedPositiveEvidenceAndMergeByName() async throws {
        let (_, _, r) = try await Self.archive()
        let suggestions = try r.relationSuggestions()
        let bank = try #require(suggestions.first { $0.name == "Sparkasse" })
        #expect(Set(bank.domains) == ["sparkasse.example", "s-online.example"] && bank.authenticated == 4)
        let craft = try #require(suggestions.first { $0.domains == ["handwerk.example"] })
        #expect(craft.youWrote == 1 && craft.name == "Max" && craft.evidence.contains("du hast 1× geschrieben"))
        let all = Set(suggestions.flatMap(\.domains))
        #expect(!all.contains("gmail.com") && !all.contains("own.test") && !all.contains("shop.example") && !all.contains("lotto.example"))
    }

    @Test func confirmedAndRejectedRelationsSurviveARebuild() async throws {
        let (_, writer, r) = try await Self.archive()
        let bank = try await writer.saveRelation(name: "Sparkasse KölnBonn", domains: ["info@Sparkasse.example", "https://s-online.example/x", "kaputt"],
                                                 since: Date(timeIntervalSince1970: 1_400_000_000), until: nil)
        try await writer.rejectRelation(name: "Max", domains: ["handwerk.example"])
        #expect(try r.relations().map(\.domains) == [["sparkasse.example", "s-online.example"]])
        #expect(try r.relationSuggestions().isEmpty)  // both taken: confirmed or rejected
        #expect(try r.relation(forDomain: "mail.s-online.example")?.name == "Sparkasse KölnBonn")
        try await writer.saveRelation(id: bank, name: "Sparkasse KölnBonn", domains: ["sparkasse.example"], since: nil, until: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await writer.rebuildIndex()
        let rebuilt = try r.relations(includeRejected: true)
        #expect(rebuilt.count == 2)
        let ended = try #require(rebuilt.first { $0.id == bank })
        #expect(ended.confirmed && ended.ended && ended.domains == ["sparkasse.example"])
        #expect(rebuilt.first { $0.name == "Max" }?.confirmed == false)
        await #expect(throws: ArchiveError.self) { try await writer.saveRelation(name: "  ", domains: ["a.example"], since: nil, until: nil) }
        await #expect(throws: ArchiveError.self) { try await writer.saveRelation(name: "X", domains: ["nichts"], since: nil, until: nil) }
    }

    @Test func olderMessagesGetTheirHeaderFieldsInTheBackground() async throws {
        let (layout, writer, r) = try await Self.archive()
        let raw = try Database(path: layout.indexURL.path)
        try raw.run("UPDATE messages SET auth_server = NULL, auth_dmarc = NULL, headers_v = NULL")
        #expect(try r.ownAuthServers().isEmpty)
        while try await writer.indexHeaderFields(batch: 5) > 0 {}
        #expect(try r.ownAuthServers() == ["x": ["mail.own.test"]])
    }
}

@Suite("Echtheit: Register und eigener Server (6.3b)")
struct RelationCheckTests {
    @Test func knownLookAlikeForgedAndFirstContact() async throws {
        let (_, writer, r) = try await RelationTests.archive()
        let extra: [(String, String, String, String?)] = [
            ("l1", "Sparkasse Service <service@sparkasse-kundenportal.example>", "me@own.test", "mail.own.test; dmarc=pass header.from=sparkasse-kundenportal.example"),
            ("l2", "Kundenservice <info@secure-login.example>", "me@own.test", "mail.own.test; dmarc=none"),
            ("m1", "Erika Beispiel <erika@foundation.example>", "me@own.test", "mail.own.test; dmarc=pass"),
            ("k1", "Erika Muster <erika@neu.example>", "kontakt@own.test", "mail.own.test; dmarc=pass"),
            ("f1", "info@sparkasse.example", "me@own.test", "mail.own.test; dkim=fail; spf=fail; dmarc=fail header.from=sparkasse.example"),
        ]
        _ = try await writer.ingest(extra.enumerated().map { n, m in
            (RelationTests.mail(m.0, from: m.1, to: m.2, subject: "Betreff", auth: m.3), LocationInfo(account: "x", mailbox: "INBOX", providerID: "e\(n)"))
        })
        try await writer.saveRelation(name: "Sparkasse KölnBonn", domains: ["sparkasse.example"], since: nil, until: nil)
        try await writer.saveRelation(name: "Erika Mustermann", domains: ["pfandbrief.example"], since: nil, until: nil)
        try await writer.saveNote(kind: .preference, text: "öffentlich", subject: "public:kontakt@own.test")
        let id = { (key: String) in try #require(try r.messageIDs(MessageFilter(text: "msgid:\(key)@t.test ")).first) }

        let known = try r.relationCheck(of: try id("b1"))
        #expect(known.known?.name == "Sparkasse KölnBonn" && known.lookAlike == nil && !known.isWarning)
        #expect(known.lines == ["Bekannte Beziehung „Sparkasse KölnBonn“.", "Prüfung deines Servers bestanden (dkim=pass spf=pass dmarc=pass)."])

        let lookAlike = try r.relationCheck(of: try id("l1"))  // by name and by domain label, though DMARC passed for its own domain
        #expect(lookAlike.lookAlike?.name == "Sparkasse KölnBonn" && lookAlike.isWarning)
        #expect(lookAlike.lines.first?.hasPrefix("Gibt sich als „Sparkasse KölnBonn“ aus, kommt aber von sparkasse-kundenportal.example") == true)
        #expect(try r.relationCheck(of: try id("l2")).isEmpty)  // claims nothing known
        #expect(try r.relationCheck(of: try id("m1")).lookAlike == nil)  // an Erika is no "Erika Mustermann"

        let forged = try r.relationCheck(of: try id("z1"))  // another server's "dmarc=pass" in a mail of the bank's domain
        #expect(forged.known != nil && forged.server == .foreign && forged.lines.last == "Die Prüfergebnisse in der Mail stammen nicht von deinem Server und zählen nicht.")
        let failed = try r.relationCheck(of: try id("f1"))
        #expect(failed.isWarning && failed.lines.contains { $0.hasPrefix("Prüfung deines Servers fehlgeschlagen") })

        let first = try r.relationCheck(of: try id("k1"))
        #expect(first.firstContactAt == "kontakt@own.test" && first.lines.last?.hasPrefix("Erstkontakt an deine öffentliche Adresse") == true)
        #expect(try r.relationCheck(of: try id("h1")).firstContactAt == nil)  // to another address
    }
}


@Suite("Einschätzung korrigieren (6.4b)")
struct VerdictCorrectionTests {
    @Test func theAlikeOnesAreTheModelFlaggedMailsOfTheseDomains() async throws {
        let (_, writer, r) = try await RelationTests.archive()
        let id = { (key: String) in try #require(try r.messageIDs(MessageFilter(text: "msgid:\(key)@t.test ")).first) }
        try await writer.setClassification(messageID: try id("b1"), category: .accountSecurity, source: .endpoint, model: "m", reason: "r", phishing: .likely)
        try await writer.setClassification(messageID: try id("b3"), category: .spam, source: .endpoint, model: "m", reason: "r")
        try await writer.setClassification(messageID: try id("b2"), category: .invoice, source: .endpoint, model: "m", reason: "r")  // not flagged
        try await writer.setClassification(messageID: try id("n1"), category: .spam, source: .endpoint, model: "m", reason: "r")  // other domain
        let flagged = try r.modelFlagged(fromDomains: ["sparkasse.example", "s-online.example"], excluding: try id("b1"))
        #expect(flagged == [try id("b3")])
        try await writer.confirmNotSpam(identity: try #require(try r.identities(of: [try id("b3")]).first))
        #expect(try r.modelFlagged(fromDomains: ["sparkasse.example", "s-online.example"]) == [try id("b1")])  // the user's word ends it
    }

    @Test("TJ's school: one sender name, two domains — both proposed, both rechecked; never the user's own domain")
    func sisterDomainsOfOneSender() async throws {
        let (_, writer, r) = try await RelationTests.archive()
        let school = "Gymnasium Musterstadt via Schulportal"
        let pass = { (d: String) in "mail.own.test; dmarc=pass header.from=\(d)" }
        _ = try await writer.ingest([
            (RelationTests.mail("s1", from: "\(school) <mail@schulportal-mail1.example>", subject: "Neue Nachricht", auth: pass("schulportal-mail1.example")),
             LocationInfo(account: "x", mailbox: "INBOX", providerID: "s1")),
            (RelationTests.mail("s2", from: "\(school) <mail@schulportal-cdn.example>", subject: "Neue Nachricht", auth: pass("schulportal-cdn.example")),
             LocationInfo(account: "x", mailbox: "INBOX", providerID: "s2")),
            (RelationTests.mail("s3", from: "\(school) <mail@schulportal-fake.example>", subject: "Neue Nachricht", auth: "evil.example; dmarc=pass"),
             LocationInfo(account: "x", mailbox: "INBOX", providerID: "s3")),
        ])
        let id = { (key: String) in try #require(try r.messageIDs(MessageFilter(text: "msgid:\(key)@t.test ")).first) }
        let proposal = try r.proposedRelation(for: try id("s1"), replyTo: "eltern@own.test")
        #expect(proposal.name == school && proposal.domains.map(\.domain) == ["schulportal-mail1.example", "schulportal-cdn.example"])  // not the forged one, not own.test
        #expect(proposal.domains.map(\.evidence) == [true, false])  // the sister domain is offered, not pre-selected (review 6 S2)
        let bank = try r.proposedRelation(for: try id("b1"), replyTo: "service@sparkasse-bank.example")
        #expect(bank.domains.map(\.domain) == ["sparkasse.example", "s-online.example", "sparkasse-bank.example"])
        #expect(bank.domains.map(\.evidence) == [true, true, false])  // s-online: authenticated statements; the Reply-To: nothing
        try await writer.setClassification(messageID: try id("s2"), category: .notification, source: .endpoint, model: "m", reason: "r", phishing: .suspicious)
        #expect(try r.modelFlagged(fromDomains: ["schulportal-mail1.example"], orName: school, excluding: try id("s1")) == [try id("s2")])
    }
}


@Suite("Review 6: own server, warnings, rejected vs forgotten, drafts")
struct ReviewSixTests {
    @Test("B1: five forged headers do not make a server 'own'; a majority or the host does; a move keeps both")
    func theOwnServerCannotBeForged() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "own"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        var batch: [(data: Data, location: LocationInfo)] = []
        for n in 0..<40 { batch.append((RelationTests.mail("p\(n)", from: "a\(n)@plain.example", subject: "Hallo"), LocationInfo(account: "plain", mailbox: "INBOX", providerID: "p\(n)"))) }
        for n in 0..<6 {
            batch.append((RelationTests.mail("f\(n)", from: "info@bank.example", subject: "Konto", auth: "mx.evil.example; dmarc=pass header.from=bank.example"),
                          LocationInfo(account: "plain", mailbox: "INBOX", providerID: "f\(n)")))
        }
        // an account that moved: 30 old mails from one server, 25 recent ones from another
        for n in 0..<30 {
            batch.append((RelationTests.mail("o\(n)", from: "x\(n)@a.example", subject: "Alt", auth: "mail.old.example; dmarc=pass", date: "14 Mar 2019"),
                          LocationInfo(account: "moved", mailbox: "INBOX", providerID: "o\(n)")))
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM yyyy"
        for n in 0..<25 {
            batch.append((RelationTests.mail("r\(n)", from: "y\(n)@a.example", subject: "Neu", auth: "mail.new.example; dmarc=pass", date: f.string(from: .now.addingTimeInterval(-86_400))),
                          LocationInfo(account: "moved", mailbox: "INBOX", providerID: "r\(n)")))
        }
        _ = try await writer.ingest(batch)
        let r = try ArchiveReader(layout: layout)
        let own = try r.ownAuthServers()
        #expect(own["plain"] == nil)  // 6 forged headers among 46 mails
        #expect(own["moved"] == ["mail.old.example", "mail.new.example"])
        #expect(AuthResults.parse("mail\u{0}evil.example; dmarc=pass")?.server == nil)  // review 6 S5: a domain name or nothing
        #expect(AuthResults.parse("mx.good-host.example; dmarc=pass")?.server == "mx.good-host.example")
    }

    @Test("S1: adding the domain to the relation ends the stored look-alike warning")
    func warningsFollowTheRegister() async throws {
        let (_, writer, r) = try await RelationTests.archive()
        try await writer.saveRelation(name: "Sparkasse", domains: ["sparkasse.example"], since: nil, until: nil)
        let lure = try #require(try r.messageIDs(MessageFilter(text: "msgid:b3@t.test ")).first)  // s-online.example, same name
        try await writer.setScreened([ScreeningCandidate(id: lure, warning: "lookalike", needsModel: false)])
        #expect(try r.count(MessageFilter(text: "is:verdächtig ", ids: [lure])) == 1)
        let rel = try #require(try r.relations().first)
        try await writer.saveRelation(id: rel.id, name: rel.name, domains: rel.domains + ["s-online.example"], since: nil, until: nil)
        #expect(try await writer.refreshWarnings() >= 1)
        #expect(try r.count(MessageFilter(text: "is:verdächtig ", ids: [lure])) == 0)
    }

    @Test("S3: a forgotten relation may come back as a suggestion, a rejected one never")
    func forgottenIsNotRejected() async throws {
        let (_, writer, r) = try await RelationTests.archive()
        let id = try await writer.saveRelation(name: "Max", domains: ["handwerk.example"], since: nil, until: nil)
        #expect(!(try r.relationSuggestions().contains { $0.domains.contains("handwerk.example") }))
        try await writer.forgetMemory([id])
        #expect(try r.relationSuggestions().contains { $0.domains.contains("handwerk.example") })
        try await writer.rejectRelation(name: "Max", domains: ["handwerk.example"])
        #expect(!(try r.relationSuggestions().contains { $0.domains.contains("handwerk.example") }))
        #expect(try r.relations(includeRejected: true).filter(\.rejected).count == 1)
    }

    @Test("S6: 'Ist Spam' never takes a draft")
    func neverFromDrafts() async throws {
        let (_, writer, r) = try await SpamReviewTests.archive()
        _ = try await writer.ingest([(sampleMessage(id: "<d@t.test>", subject: "Entwurf"), LocationInfo(account: "imap", mailbox: "Drafts", uidValidity: 9, uid: 1))])
        let draft = try #require(try r.messageIDs(MessageFilter(text: "subject:entwurf ")).first)
        #expect(try r.planMarkSpam(MessageFilter(ids: [draft]), title: "x", accounts: InboxSpamTests.accounts).0.items.isEmpty)
        #expect(RemoteMailbox.looksLikeSentOrDrafts("INBOX/Entwürfe") && !RemoteMailbox.looksLikeSentOrDrafts("INBOX"))
    }
}

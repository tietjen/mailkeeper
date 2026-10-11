import Foundation
import Testing
@testable import MailKeeperKit

@Suite("What a reply adds (5.8)")
struct QuoteTests {
    @Test func quotedLinesAndAttributionsGo() {
        let german = """
        Passt, ich komme am Donnerstag.
        Gruß Jan

        Am Mo., 3. Mai 2024 um 10:00 Uhr schrieb Max Muster <max@x.de>:
        > Kommst du Donnerstag?
        > Max
        """
        #expect(QuotedText.newPart(of: german) == "Passt, ich komme am Donnerstag.\nGruß Jan")

        let wrapped = "Ja, gerne.\r\n\r\nAm Mo., 3. Mai 2024 um 10:00 Uhr schrieb Max Muster <\r\nmax@x.de>:\r\n\r\n> Frage?"
        #expect(QuotedText.newPart(of: wrapped) == "Ja, gerne.")

        let english = "Sounds good.\n\nOn Mon, May 3, 2024 at 10:00 AM Max <max@x.de> wrote:\n> Lunch?"
        #expect(QuotedText.newPart(of: english) == "Sounds good.")

        let inline = "> Kommst du?\nJa.\n> Und Anna?\nAuch."
        #expect(QuotedText.newPart(of: inline) == "Ja.\nAuch.")
    }

    @Test func outlookBlocksSeparatorsAndSignaturesEndTheNewPart() {
        let outlook = """
        Anbei die Unterlagen.

        Von: Steuerbüro <info@stb.de>
        Gesendet: Montag, 3. Mai 2024 10:00
        An: Jan
        Betreff: Unterlagen

        Bitte senden Sie uns …
        """
        #expect(QuotedText.newPart(of: outlook) == "Anbei die Unterlagen.")
        #expect(QuotedText.newPart(of: "Ok.\n\n-----Ursprüngliche Nachricht-----\nVon: x") == "Ok.")
        #expect(QuotedText.newPart(of: "Ok.\n-- \nJan Tietjen\nTel. 0228") == "Ok.")
        // "Von:" without the block below it is just text
        #expect(QuotedText.newPart(of: "Hallo\nVon: Berlin nach Bonn fahre ich morgen.\nBis dann") == "Hallo\nVon: Berlin nach Bonn fahre ich morgen.\nBis dann")
    }

    @Test func aForwardOrAnAllQuotedMailKeepsItsText() {
        let forward = "Siehe unten.\n\nAm 3. Mai schrieb Bank <info@bank.de>:\n> Ihre Karte"
        #expect(QuotedText.newPart(of: forward, subject: "WG: Ihre Karte") == forward)
        #expect(QuotedText.newPart(of: forward, subject: "Fwd: Ihre Karte") == forward)
        #expect(QuotedText.newPart(of: "> nur Zitat\n> sonst nichts") == "> nur Zitat\n> sonst nichts")
        // an attribution before any own text is not the end (top of a bottom-posted reply)
        #expect(QuotedText.newPart(of: "Am 3. Mai schrieb Max <m@x.de>:\n> Frage?\n\nAntwort.") == "Am 3. Mai schrieb Max <m@x.de>:\n\nAntwort.")
    }

    @Test func hostileInputStaysLinear() {
        let long = String(repeating: "Von: x\n", count: 50_000) + String(repeating: "> q\n", count: 50_000)
        let start = ContinuousClock.now
        _ = QuotedText.newPart(of: long)
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}

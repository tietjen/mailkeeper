import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Importers")
struct ImporterTests {
    @Test func maildirTreeWithFlagsAndMaildirPlusPlus() async throws {
        let src = tempDir()
        func put(_ box: String, _ sub: String, _ name: String, _ data: Data) throws {
            let dir = src.appending(path: box.isEmpty ? sub : "\(box)/\(sub)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appending(path: name))
        }
        for box in ["", "Sent", ".Archive.2019"] {
            for sub in ["cur", "new", "tmp"] {
                try FileManager.default.createDirectory(at: src.appending(path: box.isEmpty ? sub : "\(box)/\(sub)"), withIntermediateDirectories: true)
            }
        }
        try put("", "cur", "1552554000.M1P2.host,U=7:2,FS", sampleMessage(id: "<i1@x>", subject: "inbox"))
        try put("", "new", "1552554001.M2P2.host", sampleMessage(id: "<i2@x>", subject: "neu"))
        try put("Sent", "cur", "1552554002.M3.host:2,S", sampleMessage(id: "<s1@x>", subject: "gesendet"))
        try put(".Archive.2019", "cur", "1552554003.M4.host:2,RS", sampleMessage(id: "<i1@x>", subject: "inbox"))
        try put("", "tmp", "partial", Data("ignored".utf8))

        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "arch"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let importer = MaildirImporter(root: src, account: "mbsync")
        #expect(importer.mailboxes().map(\.name) == ["Archive/2019", "INBOX", "Sent"])
        let result = try await importer.run(writer: writer)
        #expect(result.messages == 4 && result.newMessages == 3 && result.newLocations == 1 && result.failed == 0)
        // idempotent
        let again = try await importer.run(writer: writer)
        #expect(again.unchanged == 4)

        let reader = try ArchiveReader(layout: layout)
        let ids = try reader.messageIDs(MessageFilter(account: "mbsync", mailbox: "INBOX"))
        let inboxID = try reader.summaries(ids).first { $0.subject == "inbox" }!.id
        let inbox = try reader.detail(inboxID)!
        let loc = inbox.locations.first { $0.mailbox == "INBOX" }!
        #expect(loc.flags == ["\\Flagged", "\\Seen"])
        #expect(loc.internalDate == Date(timeIntervalSince1970: 1_552_554_000))
        #expect(inbox.locations.contains { $0.mailbox == "Archive/2019" && $0.flags == ["\\Answered", "\\Seen"] })
    }

    @Test func mboxWithEscapedFromLinesAndTakeoutLabels() async throws {
        let file = tempDir().appending(path: "All mail Including Spam and Trash.mbox")
        let mbox = """
        From 1628333251070363758@xxx Thu Mar 14 09:00:00 +0000 2019
        X-GM-THRID: 1628333251070363758
        X-Gmail-Labels: Posteingang,Geöffnet,"Projekt, intern"
        From: a@example.test
        Subject: Erste
        Message-ID: <mb1@x>

        Text
        >From the start of a line
        >>From doubly escaped

        From 1628333251070363759@xxx Thu Mar 14 10:00:00 +0000 2019
        From: b@example.test
        Subject: Zweite
        Message-ID: <mb2@x>

        Zweiter Text
        """
        try Data(mbox.utf8).write(to: file)
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "arch"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let result = try await MboxImporter(file: file, account: "takeout").run(writer: writer)
        #expect(result.messages == 2 && result.newMessages == 2)

        let reader = try ArchiveReader(layout: layout)
        let first = try reader.detail(try reader.messageIDs(MessageFilter(text: "Erste"))[0])!
        let loc = first.locations[0]
        #expect(loc.mailbox == "All mail Including Spam and Trash")
        #expect(loc.labels == ["Posteingang", "Geöffnet", "Projekt, intern"])
        #expect(loc.flags == ["\\Seen"])
        #expect(loc.internalDate == Date(timeIntervalSince1970: 1_552_554_000))
        let body = String(decoding: try layout.blobs.read(first.primaryBlob), as: UTF8.self)
        #expect(body.contains("\nFrom the start of a line\n>From doubly escaped"))
        #expect(!body.hasSuffix("\n\n"))
    }

    @Test func emlFolder() async throws {
        let src = tempDir()
        try FileManager.default.createDirectory(at: src.appending(path: "2019/März"), withIntermediateDirectories: true)
        try sampleMessage(id: "<e1@x>", subject: "eins").write(to: src.appending(path: "2019/März/eins.eml"))
        try sampleMessage(id: "<e2@x>", subject: "zwei").write(to: src.appending(path: "zwei.EML"))
        try Data("not mail".utf8).write(to: src.appending(path: "readme.txt"))
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "arch"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let result = try await EMLImporter(root: src, account: "files").run(writer: writer)
        #expect(result.messages == 2)
        let boxes = try ArchiveReader(layout: layout).accounts().first?.mailboxes.map(\.name)
        #expect(boxes == ["2019/März", "Import"])
    }
}

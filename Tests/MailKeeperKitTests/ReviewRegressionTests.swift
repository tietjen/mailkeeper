import Foundation
import Testing
@testable import MailKeeperKit

/// Regressions for the Phase 1 review (Fable, 2026-10-10): B = blocker, S = should fix.
@Suite("Review regressions")
struct ReviewRegressionTests {
    @Test("B1: broken encoded words stay linear") func brokenEncodedWordsAreLinear() {
        let subject = String(repeating: "=?a?B?z", count: 20_000)  // 140 KB, no "?=" anywhere
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = MIMEParser.parse(eml("Subject: \(subject)\n\nx")) }
        #expect(elapsed < .seconds(1))
        let withClose = String(repeating: "=?a?B?z", count: 20_000) + "?="  // one late close
        let elapsed2 = clock.measure { _ = EncodedWords.decode(withClose) }
        #expect(elapsed2 < .seconds(2))
    }

    @Test("N2/N3: long headers are linear, long valid words still decode") func longHeaders() {
        let clock = ContinuousClock()
        let literal = "=?" + String(repeating: "x", count: 1_000_000) + "?="
        #expect(clock.measure { _ = EncodedWords.decode(literal) } < .seconds(1))
        let lateClose = String(repeating: "=?a?B?z", count: 150_000) + "?="
        #expect(clock.measure { _ = EncodedWords.decode(lateClose) } < .seconds(1))
        let umlauts = String(repeating: "Ü", count: 200)
        let word = "=?utf-8?B?\(Data(umlauts.utf8).base64EncodedString())?="
        #expect(EncodedWords.decode(word) == umlauts)
        let entities = String(repeating: "&amp;", count: 800_000)
        #expect(clock.measure { _ = HTMLText.toText(entities) } < .seconds(2))
    }

    @Test("N4: short Content-IDs keep inline images") func shortContentID() {
        let p = MIMEParser.parse(eml("""
        Content-Type: multipart/related; boundary=r

        --r
        Content-Type: text/html

        <img src="cid:1">
        --r
        Content-Type: image/png
        Content-ID: <1>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --r--
        """))
        #expect(p.attachments.first?.contentID == "<1>")
        #expect(p.attachments.first?.isInline == true)
    }

    @Test("N5: an archive inside the import source is skipped") func archiveInsideSource() async throws {
        let docs = tempDir()
        try sampleMessage(id: "<doc@x>", subject: "Dokument").write(to: docs.appending(path: "brief.eml"))
        let layout = try ArchiveLayout.open(at: docs.appending(path: "MailKeeper"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await EMLImporter(root: docs, account: "docs").run(writer: writer)
        let second = try await EMLImporter(root: docs, account: "docs").run(writer: writer)
        #expect(second.messages == 1 && second.unchanged == 1)
        // blobs written by the first run are .eml files inside docs/ — they must not be imported
        #expect(try ArchiveReader(layout: layout).stats().locations == 1)
    }

    @Test("B2: a reused Message-ID does not hide a different mail") func messageIDCollision() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "b2"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let a = sampleMessage(id: "<dup@example.test>", subject: "Gehaltserhoehung", from: "boss@example.test")
        let b = sampleMessage(id: "<dup@example.test>", subject: "Rechnung ueberweisen", body: "IBAN", from: "attacker@example.test")
        #expect(try await writer.ingest(a, at: LocationInfo(account: "acc", mailbox: "INBOX", providerID: "a")) == .newMessage(1))
        #expect(try await writer.ingest(b, at: LocationInfo(account: "acc", mailbox: "INBOX", providerID: "b")) == .newMessage(2))
        let reader = try ArchiveReader(layout: layout)
        #expect(try reader.messageIDs(MessageFilter(text: "ueberweisen")) == [2])
        #expect(try reader.messageIDs(MessageFilter(text: "attacker")) == [2])
        // a byte-different copy of b (Proton-style rewrite) still joins b, not a
        var bCopy = Data("X-Pm-Internal-Id: q\r\n".utf8)
        bCopy.append(b)
        #expect(try await writer.ingest(bCopy, at: LocationInfo(account: "acc", mailbox: "Proton", providerID: "c")) == .newLocation(2))
    }

    @Test("B2: degenerate Message-IDs and empty mails are not identities") func degenerateIDs() async throws {
        #expect(MessageIDs.identity("<>") == nil)
        #expect(MessageIDs.identity("<unknown>") == nil)
        #expect(MessageIDs.identity("<1>") == nil)
        #expect(MessageIDs.identity("abc@x.test") == "<abc@x.test>")
        #expect(MessageIDs.first("<>") == nil)  // never "<<>>"
        #expect(MessageIDs.first("<1>") == "<1>")  // fine for Content-ID / In-Reply-To
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "b2b"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let r1 = try await writer.ingest(Data("Message-ID: <>\r\nSubject: eins\r\n\r\nx".utf8), at: LocationInfo(account: "a", mailbox: "M", providerID: "1"))
        let r2 = try await writer.ingest(Data("Message-ID: <>\r\nSubject: zwei\r\n\r\ny".utf8), at: LocationInfo(account: "a", mailbox: "M", providerID: "2"))
        let e1 = try await writer.ingest(Data("\r\n".utf8), at: LocationInfo(account: "a", mailbox: "M", providerID: "3"))
        let e2 = try await writer.ingest(Data("\r\n\r\n".utf8), at: LocationInfo(account: "a", mailbox: "M", providerID: "4"))
        #expect(Set([r1, r2, e1, e2].map(\.messageID)).count == 4)
    }

    @Test("B3: a torn journal line does not swallow the next event") func tornLineThenAppend() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "b3"), create: true)
        do {
            let writer = try ArchiveWriter(layout: layout)
            _ = try await writer.ingest(sampleMessage(id: "<t1@x>", subject: "eins"), at: LocationInfo(account: "acc", mailbox: "INBOX", uidValidity: 1, uid: 1))
        }
        let dir = layout.journalURL.appending(path: "acc")
        let file = dir.appending(path: try FileManager.default.contentsOfDirectory(atPath: dir.path).first!)
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{\"k\":\"seen\",\"t\":17000".utf8))  // crash mid-line
        try h.close()
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest(sampleMessage(id: "<t2@x>", subject: "zwei"), at: LocationInfo(account: "acc", mailbox: "INBOX", uidValidity: 1, uid: 2))
        let report = try await writer.rebuildIndex()
        #expect(report.locations == 2)
        #expect(try ArchiveReader(layout: layout).stats().messages == 2)
    }

    @Test("B4: rebuild survives missing and damaged blobs") func rebuildWithBadBlobs() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "b4"), create: true)
        let writer = try ArchiveWriter(layout: layout)  // no register(): account placeholder path
        var shas: [String] = []
        for n in 1...5 {
            let data = sampleMessage(id: "<bb\(n)@x>", subject: "Nachricht \(n)")
            shas.append(sha256Hex(data))
            _ = try await writer.ingest(data, at: LocationInfo(account: "acc", mailbox: "INBOX", uidValidity: 1, uid: UInt32(n)))
        }
        try FileManager.default.removeItem(at: layout.blobs.url(for: shas[2]))
        try Data("tampered".utf8).write(to: layout.blobs.url(for: shas[1]))
        let report = try await writer.rebuildIndex()
        #expect(report.missingBlobs == [shas[2]])
        #expect(report.damagedBlobs == [shas[1]])
        #expect(report.locations == 4)
        let stats = try ArchiveReader(layout: layout).stats()
        #expect(stats.messages == 4)
        #expect(try await writer.verifyBlobs() == [shas[1]])
    }

    @Test("S1: flag and label changes survive a rebuild") func flagChangesAreJournalled() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "s1"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let data = sampleMessage(id: "<f@x>", subject: "Flags")
        _ = try await writer.ingest(data, at: LocationInfo(account: "acc", mailbox: "INBOX", uidValidity: 1, uid: 1))
        #expect(try await writer.ingest(data, at: LocationInfo(account: "acc", mailbox: "INBOX", uidValidity: 1, uid: 1,
                                                                flags: ["\\Seen", "\\Flagged"], labels: ["Wichtig"])) == .unchanged(1))
        _ = try await writer.rebuildIndex()
        let loc = try ArchiveReader(layout: layout).detail(1)!.locations[0]
        #expect(loc.flags == ["\\Seen", "\\Flagged"])
        #expect(loc.labels == ["Wichtig"])
    }

    @Test("S2 + S3: open() leaves staging files alone; files are private even in a 0755 folder")
    func stagingAndPermissions() async throws {
        let root = tempDir().appending(path: "s3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let layout = try ArchiveLayout.open(at: root, create: true)
        let part = layout.tmpURL.appending(path: "x.part")
        try Data("in flight".utf8).write(to: part)
        _ = try ArchiveLayout.open(at: root, create: false)
        #expect(FileManager.default.fileExists(atPath: part.path))  // a second process must not delete it
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest(sampleMessage(id: "<p@x>", subject: "p"), at: LocationInfo(account: "a", mailbox: "M", providerID: "1"))
        #expect(!FileManager.default.fileExists(atPath: part.path))  // the lock holder cleans up
        #expect(posixMode(root) == 0o700)
        #expect(posixMode(layout.indexURL) == 0o600)
    }

    @Test("S4: a long-lived reader keeps working across a rebuild") func readerSurvivesRebuild() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "s4"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest(sampleMessage(id: "<r@x>", subject: "Reader"), at: LocationInfo(account: "a", mailbox: "M", providerID: "1"))
        let reader = try ArchiveReader(layout: layout)
        #expect(try reader.stats().messages == 1)
        _ = try await writer.rebuildIndex()
        #expect(try reader.stats().messages == 1)
        #expect(try reader.messageIDs(MessageFilter(text: "Reader")) == [1])
        #expect(!FileManager.default.fileExists(atPath: layout.root.appending(path: "index.rebuild.sqlite-wal").path))
    }

    @Test("S5: thousands of delimiters stop at the part budget") func delimiterFlood() {
        let body = "Content-Type: multipart/mixed; boundary=b\n\n" + String(repeating: "--b\n", count: 200_000)
        let p = MIMEParser.parse(eml(body))
        #expect(p.truncated)
        #expect(MIMEParser.splitMultipart(Data(String(repeating: "--b\n", count: 50_000).utf8), boundary: "b", limit: 10).count <= 11)
    }

    @Test("S8: mbox parsing is independent of chunk boundaries") func mboxTinyChunks() async throws {
        let file = tempDir().appending(path: "x.mbox")
        let mbox = "junk line\nmore junk\nFrom a@x Thu Mar 14 09:00:00 2019\nSubject: Eins\nMessage-ID: <m1@x>\n\nText 1\n>From quoted\n\n"
            + "From b@x Thu Mar 14 10:00:00 2019\nSubject: Zwei\nMessage-ID: <m2@x>\n\nText 2\n"
        try Data(mbox.utf8).write(to: file)
        for chunk in [1, 3, 7, 64, 1 << 20] {
            let layout = try ArchiveLayout.open(at: tempDir().appending(path: "s8-\(chunk)"), create: true)
            let writer = try ArchiveWriter(layout: layout)
            var importer = MboxImporter(file: file, account: "m")
            importer.chunkSize = chunk
            let result = try await importer.run(writer: writer)
            #expect(result.messages == 2, "chunk \(chunk)")
            let reader = try ArchiveReader(layout: layout)
            let first = try reader.detail(try reader.messageIDs(MessageFilter(text: "Eins"))[0])!
            let text = String(decoding: try layout.blobs.read(first.primaryBlob), as: UTF8.self)
            #expect(text.hasSuffix("Text 1\nFrom quoted\n"), "chunk \(chunk)")
        }
    }

    @Test("Import from inside the archive is refused") func refuseArchiveAsSource() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "self"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        await #expect(throws: ArchiveError.self) {
            _ = try await EMLImporter(root: layout.blobsURL, account: "x").run(writer: writer)
        }
    }

    @Test("Blob ids and journal names cannot traverse paths") func pathSafety() {
        #expect(!BlobStore.isValidSHA("../../etc/passwd"))
        #expect(!BlobStore.isValidSHA(String(repeating: "A", count: 64)))
        #expect(BlobStore.isValidSHA(String(repeating: "a", count: 64)))
        #expect(Journal.safeComponent("..") == "___")
        #expect(Journal.safeComponent("") == "_")
        #expect(Journal.safeComponent("acc/../x") == "acc_.._x")
    }
}

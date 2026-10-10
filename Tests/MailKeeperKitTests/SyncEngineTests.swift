import Foundation
import Testing
@testable import MailKeeperKit

/// An in-memory mail server. Counts fetches so tests can prove incremental behaviour.
actor FakeSource: MailboxSource {
    struct Box {
        var mailbox: RemoteMailbox
        var uidValidity: UInt32 = 1
        var nextUID: UInt32 = 1
        var modseq: UInt64 = 1
        var messages: [UInt32: (data: Data, flags: [String], labels: [String], modseq: UInt64)] = [:]
    }

    var boxes: [String: Box] = [:]
    var current: String?
    var caps = SourceCapabilities(condstore: true)
    private(set) var fetchedUIDs: [UInt32] = []
    private(set) var fetchCalls = 0
    var failFetchAfter: Int?  // simulate a dropped connection
    var emptyUIDList = false

    init(_ boxes: [RemoteMailbox]) {
        for b in boxes { self.boxes[b.name] = Box(mailbox: b) }
    }

    @discardableResult
    func add(_ mailbox: String, _ data: Data, flags: [String] = [], labels: [String] = []) -> UInt32 {
        var box = boxes[mailbox]!
        let uid = box.nextUID
        box.nextUID += 1
        box.modseq += 1
        box.messages[uid] = (data, flags, labels, box.modseq)
        boxes[mailbox] = box
        return uid
    }

    func setFlags(_ mailbox: String, _ uid: UInt32, _ flags: [String], labels: [String] = []) {
        boxes[mailbox]!.modseq += 1
        let m = boxes[mailbox]!.messages[uid]!
        boxes[mailbox]!.messages[uid] = (m.data, flags, labels, boxes[mailbox]!.modseq)
    }

    func expunge(_ mailbox: String, _ uid: UInt32) { boxes[mailbox]!.messages[uid] = nil }

    /// Server rebuilt its UIDs (Proton Bridge "repair"): same messages, new numbers.
    func renumber(_ mailbox: String) {
        var box = boxes[mailbox]!
        let old = box.messages.sorted { $0.key < $1.key }.map(\.value)
        box.uidValidity += 1
        box.messages = [:]
        box.nextUID = 1
        for m in old { box.messages[box.nextUID] = m; box.nextUID += 1 }
        boxes[mailbox] = box
    }

    func setFailFetchAfter(_ n: Int?) { failFetchAfter = n }
    func setEmptyUIDList(_ on: Bool) { emptyUIDList = on }
    func resetCounters() { fetchedUIDs = []; fetchCalls = 0 }

    // MailboxSource
    func capabilities() async -> SourceCapabilities { caps }
    func mailboxes() async throws -> [RemoteMailbox] { boxes.values.map(\.mailbox).sorted { $0.name < $1.name } }
    func examine(_ mailbox: RemoteMailbox) async throws -> MailboxStatus {
        current = mailbox.name
        let b = boxes[mailbox.name]!
        return MailboxStatus(uidValidity: b.uidValidity, uidNext: b.nextUID, exists: b.messages.count, highestModSeq: b.modseq)
    }
    func messageSizes(fromUID: UInt32) async throws -> [UIDSize] {
        let b = boxes[current!]!
        var out = b.messages.filter { $0.key >= fromUID }.map { UIDSize(uid: $0.key, size: $0.value.data.count) }
        if out.isEmpty, let last = b.messages.keys.max() { out = [UIDSize(uid: last, size: b.messages[last]!.data.count)] }  // "n:*" quirk
        return out.sorted { $0.uid < $1.uid }
    }
    func allUIDs() async throws -> [UInt32] { emptyUIDList ? [] : boxes[current!]!.messages.keys.sorted() }
    func flags(changedSince modseq: UInt64?) async throws -> [RemoteFlags] {
        boxes[current!]!.messages.filter { modseq == nil || $0.value.modseq > modseq! }
            .map { RemoteFlags(uid: $0.key, flags: $0.value.flags, labels: $0.value.labels) }
    }
    func fetch(_ uids: [UInt32]) async throws -> [RemoteMessage] {
        if let n = failFetchAfter, fetchCalls >= n { throw URLError(.networkConnectionLost) }
        fetchCalls += 1
        fetchedUIDs += uids
        let b = boxes[current!]!
        return uids.compactMap { uid in
            b.messages[uid].map { RemoteMessage(uid: uid, flags: $0.flags, labels: $0.labels, data: $0.data) }
        }
    }
}

@Suite("Sync engine")
struct SyncEngineTests {
    let inbox = RemoteMailbox(name: "INBOX")
    let account = AccountInfo(id: "acc", kind: "imap", name: "Konto")

    func archive(_ name: String) throws -> (ArchiveLayout, ArchiveWriter) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: name), create: true)
        return (layout, try ArchiveWriter(layout: layout))
    }

    func mail(_ n: Int, _ subject: String = "Mail") -> Data {
        sampleMessage(id: "<sync-\(n)@x>", subject: "\(subject) \(n)")
    }

    @Test func initialThenIncremental() async throws {
        let (layout, writer) = try archive("inc")
        let source = FakeSource([inbox, RemoteMailbox(name: "Sent", specialUse: [.sent])])
        for n in 1...5 { await source.add("INBOX", mail(n)) }
        await source.add("Sent", mail(6))
        let engine = SyncEngine(writer: writer, account: account, policy: SyncPolicy(mode: .standard))
        let first = try await engine.run(source: source)
        #expect(first.newMessages == 6 && first.fetched == 6 && first.failures.isEmpty)

        await source.resetCounters()
        let again = try await engine.run(source: source)
        #expect(again.fetched == 0 && again.newMessages == 0)
        #expect(await source.fetchedUIDs.isEmpty)

        await source.add("INBOX", mail(7))
        let third = try await engine.run(source: source)
        #expect(third.newMessages == 1)
        #expect(await source.fetchedUIDs == [6])
        #expect(try ArchiveReader(layout: layout).stats().messages == 7)
    }

    @Test func flagChangesAndDeletionsSurviveRebuild() async throws {
        let (layout, writer) = try archive("flags")
        let source = FakeSource([inbox])
        let a = await source.add("INBOX", mail(1))
        let b = await source.add("INBOX", mail(2))
        let engine = SyncEngine(writer: writer, account: account, policy: SyncPolicy(mode: .standard))
        _ = try await engine.run(source: source)
        await source.setFlags("INBOX", a, ["\\Seen", "\\Flagged"])
        await source.expunge("INBOX", b)
        let report = try await engine.run(source: source)
        #expect(report.flagChanges == 1 && report.gone == 1)
        _ = try await writer.rebuildIndex()
        let reader = try ArchiveReader(layout: layout)
        #expect(try reader.detail(1)?.locations.first?.flags == ["\\Seen", "\\Flagged"])
        #expect(try reader.detail(2)?.locations.first?.onServer == false)
        #expect(try reader.stats().messages == 2)  // gone from the server, not from the archive
    }

    @Test func uidValidityChangeRefetchesWithoutDuplicates() async throws {
        let (layout, writer) = try archive("uidv")
        let source = FakeSource([inbox])
        for n in 1...3 { await source.add("INBOX", mail(n)) }
        let engine = SyncEngine(writer: writer, account: account, policy: SyncPolicy(mode: .standard))
        _ = try await engine.run(source: source)
        await source.renumber("INBOX")
        let report = try await engine.run(source: source)
        #expect(report.gone == 3 && report.fetched == 3 && report.newMessages == 0 && report.newLocations == 3)
        let stats = try ArchiveReader(layout: layout).stats()
        #expect(stats.messages == 3 && stats.blobs == 3 && stats.locations == 6)
    }

    @Test func gmailSyncsAllMailWithLabelsOnly() async throws {
        let (layout, writer) = try archive("gmail")
        let all = RemoteMailbox(name: "[Gmail]/Alle Nachrichten", specialUse: [.all])
        let source = FakeSource([inbox, all, RemoteMailbox(name: "[Gmail]/Papierkorb", specialUse: [.trash]),
                                 RemoteMailbox(name: "[Gmail]", selectable: false)])
        await source.add("[Gmail]/Alle Nachrichten", mail(1), labels: ["\\Inbox", "Rechnungen"])
        await source.add("INBOX", mail(1))  // the same mail via a label folder
        let report = try await SyncEngine(writer: writer, account: account, policy: SyncPolicy(mode: .gmail)).run(source: source)
        #expect(report.mailboxes == 1 && report.newMessages == 1)
        let loc = try ArchiveReader(layout: layout).detail(1)!.locations
        #expect(loc.map(\.mailbox) == ["[Gmail]/Alle Nachrichten"])
        #expect(loc[0].labels == ["\\Inbox", "Rechnungen"])
    }

    @Test func protonSkipsAllMailLabelsJunkAndTrash() {
        let boxes = [inbox, RemoteMailbox(name: "All Mail", specialUse: [.all]), RemoteMailbox(name: "Labels/Wichtig"),
                     RemoteMailbox(name: "Folders/Projekte"), RemoteMailbox(name: "Spam", specialUse: [.junk]),
                     RemoteMailbox(name: "Trash", specialUse: [.trash]), RemoteMailbox(name: "Sent", specialUse: [.sent])]
        #expect(SyncPolicy(mode: .protonBridge).select(boxes).map(\.name) == ["INBOX", "Folders/Projekte", "Sent"])
        #expect(SyncPolicy(mode: .protonBridge, include: ["Folders/Projekte"]).select(boxes).map(\.name) == ["Folders/Projekte"])
        #expect(SyncPolicy(mode: .standard, exclude: ["Sent"]).select(boxes).map(\.name) == ["INBOX", "Labels/Wichtig", "Folders/Projekte"])
    }

    @Test func batchesAreBounded() async throws {
        let (_, writer) = try archive("batch")
        let source = FakeSource([inbox])
        for n in 1...5 { await source.add("INBOX", mail(n)) }
        var engine = SyncEngine(writer: writer, account: account, policy: SyncPolicy(mode: .standard))
        engine.batchCount = 2
        _ = try await engine.run(source: source)
        #expect(await source.fetchCalls == 3)
    }

    @Test func interruptedSyncResumesWithoutDuplicates() async throws {
        let (layout, writer) = try archive("resume")
        let source = FakeSource([inbox])
        for n in 1...6 { await source.add("INBOX", mail(n)) }
        var engine = SyncEngine(writer: writer, account: account, policy: SyncPolicy(mode: .standard))
        engine.batchCount = 2
        await source.setFailFetchAfter(2)  // connection drops during the third batch
        let broken = try await engine.run(source: source)
        #expect(broken.failures.count == 1 && broken.newMessages == 4)
        await source.setFailFetchAfter(nil)
        await source.resetCounters()
        let resumed = try await engine.run(source: source)
        #expect(resumed.newMessages == 2)
        #expect(await source.fetchedUIDs == [5, 6])
        #expect(try ArchiveReader(layout: layout).stats().messages == 6)
    }

    @Test func emptyUIDListIsNotAMassDeletion() async throws {
        let (layout, writer) = try archive("glitch")
        let source = FakeSource([inbox])
        for n in 1...3 { await source.add("INBOX", mail(n)) }
        let engine = SyncEngine(writer: writer, account: account, policy: SyncPolicy(mode: .standard))
        _ = try await engine.run(source: source)
        await source.setEmptyUIDList(true)
        let report = try await engine.run(source: source)
        #expect(report.gone == 0)
        #expect(try ArchiveReader(layout: layout).detail(1)?.locations.first?.onServer == true)
    }

    @Test func condstoreOnlyAsksForChanges() async throws {
        let (_, writer) = try archive("condstore")
        let source = FakeSource([inbox])
        let a = await source.add("INBOX", mail(1))
        await source.add("INBOX", mail(2))
        let engine = SyncEngine(writer: writer, account: account, policy: SyncPolicy(mode: .standard))
        _ = try await engine.run(source: source)
        let state = try await writer.mailboxState(account: "acc", mailbox: "INBOX")
        #expect(state.highestModSeq == 3 && state.modSeqValidity == 1)
        await source.setFlags("INBOX", a, ["\\Seen"])
        let report = try await engine.run(source: source)
        #expect(report.flagChanges == 1)
    }
}

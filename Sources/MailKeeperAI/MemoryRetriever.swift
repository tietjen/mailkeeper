import Foundation
import MailKeeperKit

/// What the memory adds to a model request about one mail (ADR-0005 §3, Phase 6.2): the user's
/// notes that concern it, MailKeeper's facts about the sender, and the user's decisions on mails
/// from the same sender or with similar content. `sources` names them for "Warum?".
public struct MemoryContext: Sendable, Equatable {
    /// The user's own words — trusted, outside the fence.
    public var notes: [String] = []
    /// MailKeeper's counts about the sender address — outside the fence.
    public var profile: [String] = []
    /// "Absender …, Betreff „…“ → Arbeit": the decision is the user's, sender and subject are
    /// mail text — inside the fence.
    public var examples: [String] = []
    /// The register's and the own server's word (6.3b) — outside the fence.
    public var relation: [String] = []
    /// The own server's verdict; replaces the results the mail itself carries (which may come
    /// from anywhere).
    public var server: RelationCheck.Server?
    public var sources: [String] = []

    public init() {}

    public var isEmpty: Bool { notes.isEmpty && profile.isEmpty && examples.isEmpty && relation.isEmpty }

    func render(_ fence: Fence) -> String {
        var parts: [String] = []
        if !relation.isEmpty { parts.append("MailKeepers Prüfung (Beziehungsregister des Nutzers und sein eigener Server):\n" + relation.map { "- " + $0 }.joined(separator: "\n")) }
        if !notes.isEmpty { parts.append("Notizen des Nutzers:\n" + notes.map { "- " + $0 }.joined(separator: "\n")) }
        if !profile.isEmpty { parts.append("MailKeeper über die Absenderadresse:\n" + profile.map { "- " + $0 }.joined(separator: "\n")) }
        if !examples.isEmpty {
            parts.append("So hat der Nutzer verwandte Mails eingeordnet (die Entscheidung steht nach dem Pfeil; Absender und Betreff sind fremder Text):\n"
                         + fence.wrap(examples.joined(separator: "\n")))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Picks the memory for each mail of a run: notes by scope and subject, the sender profile, and
/// up to four examples — same sender first, then same domain, then similar content (cosine ≥
/// 0.80 against the examples' vectors, which are loaded once; the whole index never is).
public struct MemoryRetriever {
    let reader: ArchiveReader
    let notes: [MemoryItem]
    let examples: [(item: MemoryItem, messageID: Int64?)]
    let exampleVectors: VectorIndex
    let embedModel: String?
    let relations: [Relation]
    let servers: [String: String]
    let publicAddresses: [String]

    public static let maxNotes = 8
    public static let maxNoteChars = 1_500
    public static let maxExamples = 4
    public static let minSimilarity: Float = 0.80

    public init(reader: ArchiveReader, embedModel: String?) throws {
        self.reader = reader
        self.embedModel = embedModel
        relations = try reader.relations()
        servers = try reader.ownAuthServers()
        publicAddresses = try reader.publicAddresses()
        let items = try reader.memoryItems()
        notes = items.filter { $0.kind == .preference || $0.kind == .vocabulary }
        let ex = items.filter { $0.kind == .example }
        let ids = try reader.messageIDs(identities: ex.compactMap(\.sources.first))
        examples = ex.map { ($0, $0.sources.first.flatMap { ids[$0] }) }
        if let embedModel, !examples.isEmpty {
            exampleVectors = try reader.vectors(of: examples.compactMap(\.messageID), model: embedModel)
        } else {
            exampleVectors = VectorIndex(ids: [], dim: 0, matrix: [])
        }
    }

    public var isEmpty: Bool { notes.isEmpty && examples.isEmpty }

    public func context(for messageID: Int64, mail: MailSnapshot, accounts: [String]) throws -> MemoryContext {
        var ctx = MemoryContext()
        let check = try reader.relationCheck(of: messageID, relations: relations, servers: servers, publicAddresses: publicAddresses)
        ctx.relation = check.lines
        ctx.server = check.server
        for r in [check.known, check.lookAlike].compactMap({ $0 }) { ctx.sources.append(r.id) }
        let sender = mail.from.lowercased()
        let host = sender.split(separator: "@").last.map(String.init)
        let domain = host.map(LinkCheck.registrableDomain)
        let list = mail.listID?.lowercased()

        var chars = 0
        for note in notes where note.scope.isEmpty || accounts.contains(note.scope) {
            let about = note.subject.lowercased()
            let relevant = about.isEmpty || about == "sender:\(sender)" || (host.map { about == "domain:\($0)" } ?? false)
                || (domain.map { about == "domain:\($0)" } ?? false) || (list.map { about == "list:\($0)" } ?? false)
            guard relevant, ctx.notes.count < Self.maxNotes, let text = note.content.text else { continue }
            let line = PromptText.line(text, max: Memory.maxText) + (about.isEmpty ? "" : " (zu \(PromptText.line(about, max: 80)))")
                + (note.kind == .vocabulary ? " [Begriff]" : "")
            guard chars + line.count <= Self.maxNoteChars else { continue }
            chars += line.count
            ctx.notes.append(line)
            ctx.sources.append(note.id)
        }

        if let profile = try reader.senderProfile(of: messageID) {
            ctx.profile = profile.lines
            ctx.sources.append(profile.sourceID)
        }

        var chosen: [MemoryItem] = []
        let others = examples.filter { $0.messageID != messageID }
        func take(_ candidates: [MemoryItem], _ limit: Int) {
            for item in candidates.sorted(by: { $0.updated > $1.updated }) where chosen.count < limit && !chosen.contains(where: { $0.id == item.id }) {
                chosen.append(item)
            }
        }
        take(others.map(\.item).filter { !sender.isEmpty && $0.content.sender == sender }, 3)
        take(others.map(\.item).filter { item in
            guard let d = item.content.domain else { return false }
            return d == host || LinkCheck.registrableDomain(d) == domain
        }, Self.maxExamples)
        if chosen.count < Self.maxExamples, let embedModel, exampleVectors.count > 0,
           let query = try reader.vectors(of: [messageID], model: embedModel).vector(of: messageID) {
            let byMessage = Dictionary(others.compactMap { e in e.messageID.map { ($0, e.item) } }, uniquingKeysWith: { a, _ in a })
            let similar = exampleVectors.nearest(to: query, k: Self.maxExamples, excluding: messageID)
                .filter { $0.score >= Self.minSimilarity }.compactMap { byMessage[$0.id] }
            for item in similar where chosen.count < Self.maxExamples && !chosen.contains(where: { $0.id == item.id }) { chosen.append(item) }
        }
        for item in chosen {
            ctx.examples.append(Self.exampleLine(item))
            ctx.sources.append(item.id)
        }
        return ctx
    }

    static func exampleLine(_ item: MemoryItem) -> String {
        let c = item.content
        let decision = [c.category.flatMap(MailCategory.init(rawValue:))?.rawValue,
                        c.verdict == "ham" ? "kein Spam" : c.verdict == "spam" && c.category != "spam" ? "spam" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        return "Absender \(PromptText.line(c.sender ?? "", max: 80)), Betreff „\(PromptText.line(c.subject ?? "", max: 100))“ → \(decision)"
    }
}

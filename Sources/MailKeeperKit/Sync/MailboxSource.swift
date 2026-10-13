import Foundation

/// RFC 6154 special-use roles. Mailboxes are chosen by role, never by (localised) name.
public enum SpecialUse: String, Sendable, Codable, CaseIterable {
    case all, archive, drafts, flagged, junk, sent, trash, important
}

public struct RemoteMailbox: Sendable, Hashable {
    /// The usual names of the special mailboxes, last path component, lowercased — one list for
    /// the sync, the queries and every name veto (review 6.8 B1: the veto's list had lacked "bin",
    /// "junk mail", "bulk mail").
    public static let junkNames = ["junk", "spam", "junk e-mail", "junk-e-mail", "junk mail", "bulk mail"]
    public static let trashNames = ["trash", "papierkorb", "deleted items", "deleted messages", "gelöschte elemente", "gelöschte objekte", "bin"]
    public static let sentNames = ["sent", "sent items", "sent messages", "sent mail", "gesendet",
                                   "gesendete objekte", "gesendete elemente", "gesendete nachrichten"]
    public static let draftsNames = ["drafts", "draft", "entwürfe", "entwurf"]
    /// Names that mean the special mailbox only at the top level: "Bin" is a trash, "Projekte/bin"
    /// a user's folder (Phase 4 kept restores into it possible).
    public static let topLevelOnlyNames: Set<String> = ["bin"]

    /// Gmail-like views a rescue must not move into (All Mail would only take the inbox away).
    static let viewNames = ["all mail", "alle nachrichten", "starred", "markiert", "important", "wichtig"]

    static func lastComponent(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == "/" || $0 == "." })
        let last = (parts.last.map(String.init) ?? name).lowercased()
        return parts.count > 1 && topLevelOnlyNames.contains(last) ? "" : last
    }

    /// Without SPECIAL-USE roles: a spam folder by its usual name (rescue only moves out of it).
    public static func looksLikeJunk(_ name: String) -> Bool { junkNames.contains(lastComponent(name)) }

    /// Without SPECIAL-USE roles on the server: a name veto against writing into a trash or junk
    /// folder (never used to *find* one — deleting goes only to a role-marked \Trash).
    public static func looksLikeTrashOrJunk(_ name: String) -> Bool { (junkNames + trashNames).contains(lastComponent(name)) }

    /// Sent or drafts by their usual names ("Ist Spam" never moves out of them — review 6 S6).
    public static func looksLikeSentOrDrafts(_ name: String) -> Bool { (sentNames + draftsNames).contains(lastComponent(name)) }

    /// Where "Ablage ändern" may move a mail *from* on a server (6.9b): any selectable mailbox but
    /// trash, sent, drafts and All Mail — by role and by name (the spam folder may give: its
    /// filter learns "ham").
    public static func mayGiveForMove(name: String, uses: Set<SpecialUse>, selectable: Bool) -> Bool {
        selectable && uses.isDisjoint(with: [.trash, .sent, .drafts, .all])
            && !trashNames.contains(lastComponent(name)) && !looksLikeSentOrDrafts(name) && !viewNames.contains(lastComponent(name))
    }

    /// Where "Kein Spam" may move a mail (6.8) — the one rule for the executor and the IMAP
    /// session: INBOX, or a selectable mailbox other than the source with no role but Archive,
    /// whose name is no spam, trash, sent, drafts or a Gmail-like view (review 6.8 B1/S2).
    public static func mayTakeRescued(name: String, uses: Set<SpecialUse>, selectable: Bool, source: String) -> Bool {
        guard name != source, selectable else { return false }
        if name.uppercased() == "INBOX" { return true }
        return uses.subtracting([.archive]).isEmpty && !looksLikeTrashOrJunk(name) && !looksLikeSentOrDrafts(name)
            && !viewNames.contains(lastComponent(name))
    }

    /// Decoded display name (modified UTF-7 resolved), e.g. "[Gmail]/Entwürfe". This is the
    /// mailbox key of the archive's locations.
    public var name: String
    public var specialUse: Set<SpecialUse>
    public var selectable: Bool

    public init(name: String, specialUse: Set<SpecialUse> = [], selectable: Bool = true) {
        self.name = name
        self.specialUse = specialUse
        self.selectable = selectable
    }
}

public struct MailboxStatus: Sendable, Equatable {
    public var uidValidity: UInt32
    public var uidNext: UInt32?
    public var exists: Int
    public var highestModSeq: UInt64?

    public init(uidValidity: UInt32, uidNext: UInt32? = nil, exists: Int, highestModSeq: UInt64? = nil) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.exists = exists
        self.highestModSeq = highestModSeq
    }
}

public struct UIDSize: Sendable, Equatable {
    public var uid: UInt32
    public var size: Int

    public init(uid: UInt32, size: Int) {
        self.uid = uid
        self.size = size
    }
}

public struct RemoteMessage: Sendable {
    public var uid: UInt32
    public var flags: [String]
    public var labels: [String]
    public var internalDate: Date?
    /// Provider id where one exists (Gmail X-GM-MSGID).
    public var providerID: String?
    public var data: Data

    public init(uid: UInt32, flags: [String] = [], labels: [String] = [], internalDate: Date? = nil,
                providerID: String? = nil, data: Data) {
        self.uid = uid
        self.flags = flags
        self.labels = labels
        self.internalDate = internalDate
        self.providerID = providerID
        self.data = data
    }
}

public struct RemoteFlags: Sendable, Equatable {
    public var uid: UInt32
    public var flags: [String]
    public var labels: [String]

    public init(uid: UInt32, flags: [String], labels: [String] = []) {
        self.uid = uid
        self.flags = flags
        self.labels = labels
    }
}

public struct SourceCapabilities: Sendable, Equatable {
    public var condstore: Bool
    public var gmail: Bool

    public init(condstore: Bool = false, gmail: Bool = false) {
        self.condstore = condstore
        self.gmail = gmail
    }
}

/// What the sync engine needs from a mail server — IMAP in production, a fake in tests.
/// Read-only by design: nothing here can change server state. Calls after `examine` refer
/// to the examined mailbox.
public protocol MailboxSource: Sendable {
    func capabilities() async -> SourceCapabilities
    func mailboxes() async throws -> [RemoteMailbox]
    func examine(_ mailbox: RemoteMailbox) async throws -> MailboxStatus
    /// UIDs ≥ `fromUID` with their RFC822.SIZE, ascending.
    func messageSizes(fromUID: UInt32) async throws -> [UIDSize]
    /// Every UID in the mailbox.
    func allUIDs() async throws -> [UInt32]
    /// Flags (and Gmail labels) of all messages, or only those changed since a MODSEQ.
    func flags(changedSince modseq: UInt64?) async throws -> [RemoteFlags]
    /// Full messages without setting \Seen. Callers bound the batch size.
    func fetch(_ uids: [UInt32]) async throws -> [RemoteMessage]
}

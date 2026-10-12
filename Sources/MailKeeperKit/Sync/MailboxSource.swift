import Foundation

/// RFC 6154 special-use roles. Mailboxes are chosen by role, never by (localised) name.
public enum SpecialUse: String, Sendable, Codable, CaseIterable {
    case all, archive, drafts, flagged, junk, sent, trash, important
}

public struct RemoteMailbox: Sendable, Hashable {
    /// Without SPECIAL-USE roles on the server: a name veto against writing into a trash or junk
    /// folder (never used to *find* one — deleting goes only to a role-marked \Trash).
    /// Without SPECIAL-USE roles: a spam folder by its usual name (rescue only moves out of it).
    public static func looksLikeJunk(_ name: String) -> Bool {
        let last = (name.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? name).lowercased()
        return ["junk", "spam", "junk e-mail", "junk-e-mail", "junk mail", "bulk mail"].contains(last)
    }

    public static func looksLikeTrashOrJunk(_ name: String) -> Bool {
        let last = (name.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? name).lowercased()
        return ["trash", "junk", "spam", "deleted items", "deleted messages", "papierkorb", "gelöschte elemente",
                "gelöschte objekte", "junk-e-mail"].contains(last)
    }

    /// Without SPECIAL-USE roles: sent or drafts by their usual names ("Ist Spam" never moves
    /// out of them — review 6 S6).
    public static func looksLikeSentOrDrafts(_ name: String) -> Bool {
        let last = (name.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? name).lowercased()
        return ["sent", "sent items", "sent messages", "sent mail", "gesendet", "gesendete objekte", "gesendete elemente",
                "gesendete nachrichten", "drafts", "draft", "entwürfe", "entwurf"].contains(last)
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

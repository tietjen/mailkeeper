import Foundation

/// The XPC interface of the PDF text service (ADR-0009). Only bytes in, text and a status out.
@objc public protocol AttachmentTextService {
    /// `reply(status, text, detail)`; status is an `AttachmentText.Status` raw value.
    func extractText(fromPDF pdf: Data, reply: @escaping (String, String, String?) -> Void)
}

/// Text of a message's PDF attachments and how extracting it went.
public struct AttachmentText: Sendable, Equatable {
    public enum Status: String, Sendable, CaseIterable {
        /// Text found and searchable.
        case ok
        /// Readable, but no text (scans, images).
        case empty
        /// Needs a password.
        case encrypted
        /// Over the size or page limit.
        case tooLarge
        /// Not a readable PDF, or the service crashed or timed out on it.
        case failed
    }

    public var status: Status
    public var text: String
    public var detail: String?

    public init(status: Status, text: String = "", detail: String? = nil) {
        self.status = status
        self.text = text
        self.detail = detail
    }
}

/// Turns one PDF into text: the XPC service in the app, a fake in tests.
public protocol AttachmentTextExtractor: Sendable {
    func extractText(pdf: Data) async throws -> AttachmentText
}

public struct AttachmentIndexProgress: Sendable, Equatable {
    /// Messages waiting when the run started.
    public var total = 0
    public var done = 0
    public var searchable = 0
    public var failed = 0

    public init() {}
}

/// Background queue (ADR-0009): makes PDF attachments searchable, newest messages first, one
/// message at a time. Cancel it to free the writer for import or sync; it resumes later.
public struct AttachmentIndexer: Sendable {
    /// Bump to retry failed messages with an improved extractor.
    public static let version = 1
    public static let maxPDFBytes = 100 << 20
    /// All PDFs of one message together (the body is capped the same way).
    public static let maxCharacters = 1 << 20

    public let writer: ArchiveWriter
    public let extractor: any AttachmentTextExtractor

    public init(writer: ArchiveWriter, extractor: any AttachmentTextExtractor) {
        self.writer = writer
        self.extractor = extractor
    }

    public func run(progress: @escaping @Sendable (AttachmentIndexProgress) -> Void = { _ in }) async throws -> AttachmentIndexProgress {
        var p = AttachmentIndexProgress()
        p.total = try await writer.pendingAttachmentTextCount(version: Self.version)
        progress(p)
        while true {
            try Task.checkCancellation()
            let batch = try await writer.pendingAttachmentText(limit: 20, version: Self.version)
            if batch.isEmpty { break }
            for item in batch {
                try Task.checkCancellation()
                let result = try await text(ofBlob: item.sha256)
                // Every queued message gets a row, whatever happened: the queue always shrinks.
                try await writer.setAttachmentText(messageID: item.id, result, version: Self.version)
                p.done += 1
                if result.status == .ok { p.searchable += 1 }
                if result.status == .failed { p.failed += 1 }
                progress(p)
            }
        }
        return p
    }

    static func isPDF(_ a: AttachmentInfo) -> Bool {
        !a.isInline && (a.mimeType == "application/pdf" || a.filename?.lowercased().hasSuffix(".pdf") == true)
    }

    /// Throws only CancellationError: a cancelled run must not record the message as failed.
    func text(ofBlob sha: String) async throws -> AttachmentText {
        let parsed: ParsedMessage
        do { parsed = MIMEParser.parse(try writer.layout.blobs.read(sha)) } catch {
            return AttachmentText(status: .failed, detail: "\(error)")
        }
        var texts: [String] = []
        var outcomes: [AttachmentText] = []
        for attachment in parsed.attachments where Self.isPDF(attachment) {
            guard let bytes = parsed.data(of: attachment) else {
                outcomes.append(AttachmentText(status: .failed, detail: "part not found"))
                continue
            }
            guard bytes.count <= Self.maxPDFBytes else {
                outcomes.append(AttachmentText(status: .tooLarge, detail: "\(bytes.count) bytes"))
                continue
            }
            do {
                let r = try await extractor.extractText(pdf: bytes)
                outcomes.append(r)
                if !r.text.isEmpty { texts.append(r.text) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcomes.append(AttachmentText(status: .failed, detail: "\(error)"))
            }
        }
        var text = texts.joined(separator: "\n\n")
        if text.count > Self.maxCharacters { text = String(text.prefix(Self.maxCharacters)) }
        if !text.isEmpty { return AttachmentText(status: .ok, text: text) }
        // No text at all: report the most telling reason.
        let reason = outcomes.first { $0.status != .empty && $0.status != .ok } ?? outcomes.first ?? AttachmentText(status: .empty)
        return AttachmentText(status: reason.status == .ok ? .empty : reason.status, detail: reason.detail)
    }
}

public struct AttachmentTextStats: Sendable, Equatable {
    /// Messages with at least one PDF attachment.
    public var withPDF = 0
    public var byStatus: [AttachmentText.Status: Int] = [:]

    public var done: Int { byStatus.values.reduce(0, +) }
    public var pending: Int { max(0, withPDF - done) }
}

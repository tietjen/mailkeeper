import Foundation
import MailKeeperKit
import PDFKit

/// The PDF parsing itself (ADR-0009). Linked only into the sandboxed PDF text service — the
/// app never parses a PDF in its own process.
///
/// PDFKit recognises text on image-only pages by itself (Live Text / TextRecognition) when a
/// page's string is read: scans become searchable, at a few seconds per page. A time budget,
/// checked between pages, keeps what was found so far instead of losing the whole file.
public enum PDFTextExtraction {
    public static let maxBytes = 100 << 20
    public static let maxPages = 500
    public static let maxCharacters = 512 << 10
    public static let timeBudget: TimeInterval = 15

    public static func extract(_ data: Data, maxPages: Int = maxPages, maxCharacters: Int = maxCharacters,
                               timeBudget: TimeInterval = timeBudget) -> AttachmentText {
        let deadline = Date().addingTimeInterval(timeBudget)
        guard data.count <= maxBytes else { return AttachmentText(status: .tooLarge, detail: "\(data.count) bytes") }
        // Readers accept junk before the header; PDFKit tolerates up to 1 KiB of it, so do we.
        guard data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil else {
            return AttachmentText(status: .failed, detail: "not a PDF")
        }
        guard let document = PDFDocument(data: data) else { return AttachmentText(status: .failed, detail: "unreadable PDF") }
        // Many PDFs are "encrypted" with an empty user password (print/copy restrictions only).
        if document.isLocked, !document.unlock(withPassword: "") { return AttachmentText(status: .encrypted) }
        var parts: [String] = []
        var characters = 0
        let pages = document.pageCount
        var read = 0
        for index in 0..<min(pages, maxPages) {
            if index > 0, Date() > deadline { break }
            read = index + 1
            guard let page = document.page(at: index), let string = page.string, !string.isEmpty else { continue }
            parts.append(string)
            characters += string.count
            if characters >= maxCharacters { break }
        }
        var text = parts.joined(separator: "\n")
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            return AttachmentText(status: .empty, detail: pages == 0 ? "no pages" : "no text found")
        }
        let note = read < pages && characters < maxCharacters ? "first \(read) of \(pages) pages" : nil
        return AttachmentText(status: .ok, text: text, detail: note)
    }
}

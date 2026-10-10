import Foundation

public struct MIMEPart: Sendable {
    public var headers: HeaderList
    /// Lowercased `type/subtype`.
    public var contentType: String
    public var params: [String: String]
    public var disposition: String?
    public var dispositionParams: [String: String]
    public var transferEncoding: String?
    public var contentID: String?
    /// Raw body bytes, still transfer-encoded.
    public var body: Data
    public var children: [MIMEPart]

    public var decodedBody: Data { TransferEncoding.decode(body, encoding: transferEncoding) }
    public var filename: String? { dispositionParams["filename"] ?? params["name"] }
    public var isMultipart: Bool { contentType.hasPrefix("multipart/") }
    public var decodedText: String { Charset.decode(decodedBody, charset: params["charset"]) }
}

public struct AttachmentInfo: Sendable, Equatable, Codable {
    public var filename: String?
    public var mimeType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool
}

/// Everything MailKeeper derives from a raw message for the index and the reader.
public struct ParsedMessage: Sendable {
    public var root: MIMEPart
    public var headers: HeaderList { root.headers }
    public var subject: String?
    public var from: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var replyTo: [MailAddress]
    public var date: Date?
    /// Normalised `<id>`.
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var listID: String?
    public var hasListUnsubscribe: Bool
    public var precedence: String?
    public var autoSubmitted: String?
    /// Best plain text: text/plain parts, else text derived from HTML. Capped for indexing.
    public var text: String
    /// HTML body for the reader, if any.
    public var html: String?
    public var attachments: [AttachmentInfo]
    /// The parser hit a limit (depth, part count) and did not descend further.
    public var truncated: Bool
}

public enum MIMEParser {
    static let maxDepth = 20
    static let maxParts = 1_000
    static let maxTextBytes = 1 << 20

    public static func parse(_ data: Data) -> ParsedMessage {
        var budget = maxParts
        var truncated = false
        let root = parsePart(Data(data), depth: 0, budget: &budget, truncated: &truncated, defaultType: "text/plain")
        var collector = BodyCollector()
        collector.collect(root)

        let h = root.headers
        var text = collector.plain.joined(separator: "\n\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !collector.html.isEmpty {
            text = HTMLText.toText(collector.html.joined(separator: "\n"))
        }
        if text.utf8.count > maxTextBytes {
            text = String(text.utf8.prefix(maxTextBytes)) ?? String(text.prefix(maxTextBytes / 4))
        }
        return ParsedMessage(
            root: root,
            subject: h.text("Subject"),
            from: AddressParser.parse(h["From"]),
            to: AddressParser.parse(h.all("To").joined(separator: ", ")),
            cc: AddressParser.parse(h.all("Cc").joined(separator: ", ")),
            replyTo: AddressParser.parse(h["Reply-To"]),
            date: MailDate.parse(h["Date"]),
            messageID: MessageIDs.first(h["Message-ID"]),
            inReplyTo: MessageIDs.first(h["In-Reply-To"]),
            references: MessageIDs.all(h["References"]),
            listID: h["List-Id"].map { MessageIDs.all($0).first.map { String($0.dropFirst().dropLast()) } ?? $0 }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() },
            hasListUnsubscribe: h["List-Unsubscribe"] != nil,
            precedence: h["Precedence"]?.trimmingCharacters(in: .whitespaces).lowercased(),
            autoSubmitted: h["Auto-Submitted"]?.trimmingCharacters(in: .whitespaces).lowercased(),
            text: text,
            html: collector.html.isEmpty ? nil : collector.html.joined(separator: "\n"),
            attachments: collector.attachments,
            truncated: truncated
        )
    }

    static func parsePart(_ data: Data, depth: Int, budget: inout Int, truncated: inout Bool, defaultType: String) -> MIMEPart {
        budget -= 1
        let (headers, bodyOffset) = HeaderParser.parse(data)
        let body = bodyOffset < data.count ? data.subdata(in: bodyOffset..<data.count) : Data()
        let ct = headers["Content-Type"].map(ParameterizedValue.init)
        var contentType = ct?.value ?? defaultType
        if !contentType.contains("/") { contentType = defaultType }  // garbage type → default
        let disposition = headers["Content-Disposition"].map(ParameterizedValue.init)
        var part = MIMEPart(
            headers: headers,
            contentType: contentType,
            params: ct?.params ?? [:],
            disposition: disposition.map { $0.value.isEmpty ? nil : $0.value } ?? nil,
            dispositionParams: disposition?.params ?? [:],
            transferEncoding: headers["Content-Transfer-Encoding"],
            contentID: MessageIDs.first(headers["Content-ID"]),
            body: body,
            children: []
        )
        guard contentType.hasPrefix("multipart/") else { return part }
        guard depth < maxDepth, budget > 0 else { truncated = true; return part }
        guard let boundary = part.params["boundary"], !boundary.isEmpty else { return part }
        let childDefault = contentType == "multipart/digest" ? "message/rfc822" : "text/plain"
        for chunk in splitMultipart(body, boundary: boundary) {
            guard budget > 0 else { truncated = true; break }
            part.children.append(parsePart(chunk, depth: depth + 1, budget: &budget, truncated: &truncated, defaultType: childDefault))
        }
        return part
    }

    /// Body parts between `--boundary` lines (at line starts) up to `--boundary--`.
    /// The line break before a delimiter belongs to the delimiter. A missing closing
    /// delimiter ends the last part at the end of the data.
    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delim = Data("--\(boundary)".utf8)
        var starts: [(lineStart: Int, contentStart: Int, isClose: Bool)] = []
        var from = body.startIndex
        while from < body.endIndex, let r = body.range(of: delim, in: from..<body.endIndex) {
            let atLineStart = r.lowerBound == body.startIndex || body[r.lowerBound - 1] == 0x0A
            let isClose = body[r.upperBound...].starts(with: [0x2D, 0x2D])
            // "--b1" must not match "--b10": only line end, whitespace or "--" may follow.
            let next = r.upperBound < body.endIndex ? body[r.upperBound] : 0x0A
            let terminated = isClose || next == 0x0A || next == 0x0D || next == 0x20 || next == 0x09
            guard atLineStart, terminated else { from = r.upperBound; continue }
            var lineEnd = r.upperBound
            while lineEnd < body.endIndex, body[lineEnd] != 0x0A { lineEnd += 1 }
            let contentStart = min(lineEnd + 1, body.endIndex)
            starts.append((r.lowerBound, contentStart, isClose))
            from = contentStart
            if isClose { break }
        }
        var parts: [Data] = []
        for (n, s) in starts.enumerated() where !s.isClose {
            var end = n + 1 < starts.count ? starts[n + 1].lineStart : body.endIndex
            if n + 1 < starts.count {
                if end > s.contentStart, body[end - 1] == 0x0A { end -= 1 }
                if end > s.contentStart, body[end - 1] == 0x0D { end -= 1 }
            }
            parts.append(end > s.contentStart ? body.subdata(in: s.contentStart..<end) : Data())
        }
        return parts
    }
}

/// Walks the part tree: body text vs. attachments, best alternative per multipart/alternative.
private struct BodyCollector {
    var plain: [String] = []
    var html: [String] = []
    var attachments: [AttachmentInfo] = []

    mutating func collect(_ part: MIMEPart) {
        if part.contentType == "multipart/alternative" {
            var plainAlt: BodyCollector?
            var htmlAlt: BodyCollector?
            for child in part.children {
                var c = BodyCollector()
                c.collect(child)
                if !c.plain.isEmpty { plainAlt = c }
                if !c.html.isEmpty { htmlAlt = c }
                attachments += c.attachments.filter { $0.isInline == false }
            }
            plain += plainAlt?.plain ?? []
            html += htmlAlt?.html ?? []
            // inline resources (cid images) of the chosen HTML alternative
            attachments += htmlAlt?.attachments.filter(\.isInline) ?? []
            return
        }
        if part.isMultipart {
            for child in part.children { collect(child) }
            return
        }
        if isBodyText(part) {
            if part.contentType == "text/html" { html.append(part.decodedText) } else { plain.append(part.decodedText) }
            return
        }
        var name = part.filename
        if name == nil, part.contentType == "message/rfc822" {
            let inner = HeaderParser.parse(part.decodedBody).0
            name = (inner.text("Subject").map { $0.isEmpty ? "message" : $0 } ?? "message") + ".eml"
        }
        attachments.append(AttachmentInfo(
            filename: name,
            mimeType: part.contentType,
            size: part.decodedBody.count,
            contentID: part.contentID,
            isInline: part.disposition == "inline" || (part.disposition == nil && part.contentID != nil)
        ))
    }

    private func isBodyText(_ part: MIMEPart) -> Bool {
        guard part.contentType == "text/plain" || part.contentType == "text/html" else { return false }
        if part.disposition == "attachment" { return false }
        if part.disposition == nil, part.filename != nil { return false }
        return true
    }
}

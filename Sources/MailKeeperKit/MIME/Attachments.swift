import CoreServices
import Foundation
import UniformTypeIdentifiers

public extension MIMEPart {
    /// The descendant at `path` (child indices from this part).
    func part(at path: [Int]) -> MIMEPart? {
        var current = self
        for i in path {
            guard current.children.indices.contains(i) else { return nil }
            current = current.children[i]
        }
        return current
    }
}

public extension ParsedMessage {
    /// Decoded bytes of an attachment of this message.
    func data(of attachment: AttachmentInfo) -> Data? {
        root.part(at: attachment.partPath)?.decodedBody
    }
}

/// Attachments are untrusted input: names are chosen by the sender and may try to look like
/// something else ("rechnung\u{202E}fdp.exe" displays as "rechnungexe.pdf").
public enum AttachmentSafety {
    static let maxNameLength = 180

    /// A file name safe to write and honest to display: last path component only, no control
    /// or format characters (bidi overrides, zero-width), no leading dots, bounded length,
    /// an extension from the MIME type when the sender gave none.
    public static func sanitizedFilename(_ raw: String?, mimeType: String) -> String {
        var name = (raw ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { c in
            !(c.value < 0x20 || c.value == 0x7F || (0x80...0x9F).contains(c.value))
                && c.properties.generalCategory != .format
        }))
        name = name.replacingOccurrences(of: ":", with: "_")  // Finder's path separator
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }  // no hidden files
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let typeExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension
        var ext = (name as NSString).pathExtension
        var base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        if base.isEmpty { base = "Anhang" }
        if ext.isEmpty, let typeExtension { ext = typeExtension }
        let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(16))
        if base.count + suffix.count > maxNameLength {
            base = String(base.prefix(maxNameLength - suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return base + suffix
    }

    static let riskyExtensions: Set<String> = [
        "app", "pkg", "mpkg", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish",
        "py", "rb", "pl", "php", "js", "jse", "mjs", "vbs", "vbe", "wsf", "wsh", "hta", "jar",
        "exe", "com", "bat", "cmd", "msi", "msp", "scr", "pif", "cpl", "ps1", "psm1", "lnk", "reg",
        "scpt", "scptd", "applescript", "workflow", "action", "terminal", "dylib", "so", "kext",
        "prefpane", "plugin", "osax", "fileloc", "inetloc", "webloc", "dmg", "iso", "img",
        "docm", "dotm", "xlsm", "xltm", "pptm", "potm", "ppsm",
    ]

    /// Programs, scripts, installers, disk images, macro documents and link files: MailKeeper
    /// offers to save these, never to open them directly.
    public static func isRisky(filename: String, mimeType: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if riskyExtensions.contains(ext) { return true }
        let types = [UTType(filenameExtension: ext), UTType(mimeType: mimeType)].compactMap { $0 }
        return types.contains { t in
            t.conforms(to: .executable) || t.conforms(to: .application) || t.conforms(to: .applicationBundle)
                || t.conforms(to: .script) || t.conforms(to: .shellScript) || t.conforms(to: .unixExecutable)
                || t.conforms(to: .diskImage)
        }
    }

    /// Writes attachment bytes (0600) and marks the file as a quarantined mail attachment, so
    /// Gatekeeper checks it like a download when it is opened — also after "save as".
    public static func writeQuarantined(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "MailKeeper",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
        ]
        var target = url
        try target.setResourceValues(values)
    }

    /// `name`, or "name 2.ext", "name 3.ext", … if taken in `directory`.
    public static func uniqueURL(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appending(path: name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// Display-safe text for sender-controlled strings (subject, names, file names in lists):
/// bidi overrides, embeddings and isolates are removed so "rechnung\u{202E}fdp.exe" cannot
/// pose as "rechnungexe.pdf". ZWJ/ZWNJ stay (emoji sequences, scripts need them).
public enum DisplayText {
    public static func safe(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isBidiControl) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.filter { !isBidiControl($0) }))
    }

    static func isBidiControl(_ c: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(c.value) || (0x2066...0x2069).contains(c.value)
            || c.value == 0x200E || c.value == 0x200F || c.value == 0x061C
    }
}

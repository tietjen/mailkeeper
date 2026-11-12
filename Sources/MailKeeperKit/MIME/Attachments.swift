#if canImport(UniformTypeIdentifiers)
import CoreServices
import UniformTypeIdentifiers
#endif
import Foundation

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
    /// APFS allows 255 bytes per name; stay well below in UTF-8 bytes (CJK: 3 bytes/char).
    static let maxNameBytes = 200

    /// A file name safe to write and honest to display: last path component only; control,
    /// format, private-use, unassigned and line/paragraph separator characters removed; all
    /// spaces (NBSP, fillers) normalised and collapsed; no leading dots; bounded length; an
    /// extension from the MIME type when the sender gave none.
    public static func sanitizedFilename(_ raw: String?, mimeType: String) -> String {
        var name = (raw ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        name = collapseWhitespace(DisplayText.normalizedScalars(name, dropFormat: true))
        name = name.replacingOccurrences(of: ":", with: "_")  // Finder's path separator
        while name.hasPrefix(".") || name.hasPrefix(" ") { name.removeFirst() }  // no hidden files

        let typeExtension = MIMETypes.preferredExtension(for: mimeType)
        var ext = (name as NSString).pathExtension
        var base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Anhang" }
        if ext.isEmpty, let typeExtension { ext = typeExtension }
        let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(16))
        while !base.isEmpty, base.utf8.count + suffix.utf8.count > maxNameBytes { base.removeLast() }
        return base.trimmingCharacters(in: .whitespaces) + suffix
    }

    static let riskyExtensions: Set<String> = Set([
        // programs, scripts, installers
        "app", "pkg", "mpkg", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish",
        "py", "rb", "pl", "php", "js", "jse", "mjs", "vbs", "vbe", "wsf", "wsh", "hta", "jar",
        "exe", "com", "bat", "cmd", "msi", "msp", "scr", "pif", "cpl", "ps1", "psm1", "lnk", "reg",
        "scpt", "scptd", "applescript", "workflow", "action", "terminal", "dylib", "so", "kext",
        "prefpane", "plugin", "osax", "dmg", "iso", "img",
        // what UTType counts as programs, scripts and disk images — named here so Linux, which
        // has no UTType, judges them the same (review S1)
        "dll", "class", "ipa", "war", "o", "php3", "php4", "phtml", "pm", "pyc", "rbw", "tcsh", "make", "tsx",
        "sparseimage", "sparsebundle", "cdr", "dvdr", "toast", "dmgpart",
        // system configuration and automation that installs or runs things
        "mobileconfig", "provisionprofile", "shortcut", "wflow",
        // macro documents
        "docm", "dotm", "xlsm", "xltm", "pptm", "potm", "ppsm", "xlsb",
    ]).union(webExtensions)

    /// Web content and link files: opened in a browser they run script, redirect, or ask for
    /// logins (the most common phishing attachment). Shown as text, saved, never opened.
    static let webExtensions: Set<String> = [
        "html", "htm", "xhtml", "shtml", "svg", "svgz", "webarchive", "mht", "mhtml",
        "url", "webloc", "inetloc", "fileloc", "afploc", "ftploc", "mailloc",
    ]

    /// Programs, scripts, installers, disk images, configuration profiles, macro documents,
    /// web content and link files: MailKeeper offers to save these, never to open them.
    public static func isRisky(filename: String, mimeType: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if riskyExtensions.contains(ext) { return true }
        #if canImport(UniformTypeIdentifiers)
        let types = [UTType(filenameExtension: ext), UTType(mimeType: mimeType)].compactMap { $0 }
        return types.contains { t in
            t.conforms(to: .executable) || t.conforms(to: .application) || t.conforms(to: .applicationBundle)
                || t.conforms(to: .script) || t.conforms(to: .shellScript) || t.conforms(to: .unixExecutable)
                || t.conforms(to: .diskImage) || t.conforms(to: .html) || t.conforms(to: .webArchive)
                || t.conforms(to: .svg) || t.conforms(to: .internetLocation)
        } || isWebContent(filename: filename, mimeType: mimeType)
        #else
        return isRiskyByTable(filename: filename, mimeType: mimeType)
        #endif
    }

    /// The verdict without UTType — extension lists and MIME table only. Linux decides by this;
    /// on macOS a test checks it calls risky whatever UTType does.
    static func isRiskyByTable(filename: String, mimeType: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return riskyExtensions.contains(ext) || MIMETypes.isRisky(mimeType) || MIMETypes.isWebContent(mimeType)
    }

    /// Previewed as plain text instead of Quick Look (whose web generator may load remote
    /// resources — tracking, IP leak).
    public static func isWebContent(filename: String, mimeType: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if webExtensions.contains(ext) { return true }
        #if canImport(UniformTypeIdentifiers)
        let types = [UTType(filenameExtension: ext), UTType(mimeType: mimeType)].compactMap { $0 }
        return types.contains { $0.conforms(to: .html) || $0.conforms(to: .webArchive) || $0.conforms(to: .svg) || $0.conforms(to: .internetLocation) }
        #else
        return MIMETypes.isWebContent(mimeType)
        #endif
    }

    /// Writes attachment bytes (0600) quarantined as a mail attachment, so Gatekeeper checks
    /// the file like a download — also after "save as". Fail closed: the bytes go to a staging
    /// file next to the target, which is quarantined first and only then renamed into place;
    /// if quarantining fails (file systems without xattrs), nothing is left behind.
    /// `replace: false` never overwrites an existing file (atomic, no check-then-write race).
    public static func writeQuarantined(_ data: Data, to url: URL, replace: Bool = true) throws {
        let staging = url.deletingLastPathComponent().appending(path: ".mailkeeper-\(UUID().uuidString).part")
        try writeDurably(data, to: staging)
        #if canImport(UniformTypeIdentifiers)
        do {
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineAgentNameKey as String: "MailKeeper",
                kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
            ]
            var target = staging
            try target.setResourceValues(values)
            let flags = replace ? 0 : UInt32(RENAME_EXCL)
            guard renamex_np(staging.path, url.path, flags) == 0 else {
                throw CocoaError(errno == EEXIST ? .fileWriteFileExists : .fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            unlink(staging.path)
            throw error
        }
        #else
        // Linux has no quarantine; private (writeDurably: 0600) and atomic stay. Without
        // renamex_np, "never overwrite" is link + unlink: link fails if the name exists.
        let moved = replace ? rename(staging.path, url.path) : link(staging.path, url.path)
        let failure = errno
        if !replace || moved != 0 { unlink(staging.path) }
        guard moved == 0 else {
            throw CocoaError(failure == EEXIST ? .fileWriteFileExists : .fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        #endif
    }

    /// Source text of an attachment for a safe text view: at most `limit` bytes, UTF-8 or
    /// Windows-1252, without control and bidi characters (newline and tab stay).
    public static func textPreview(_ data: Data, limit: Int = 64 * 1024) -> String {
        let text = Charset.decode(data.prefix(limit), charset: "utf-8")
        let kept = text.unicodeScalars.filter { c in
            c == "\n" || c == "\t" || !(c.value < 0x20 || c.value == 0x7F || (0x80...0x9F).contains(c.value) || DisplayText.isBidiControl(c))
        }
        return String(String.UnicodeScalarView(kept)) + (data.count > limit ? "\n…" : "")
    }

    /// Writes into `directory` as `name`, or "name 2.ext", "name 3.ext", … if taken — never
    /// overwriting, even if a file appears concurrently. Returns the URL written.
    @discardableResult
    public static func writeQuarantinedUnique(_ data: Data, in directory: URL, name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...10_000 {
            let candidate = directory.appending(path: n == 1 ? name : (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"))
            do {
                try writeQuarantined(data, to: candidate, replace: false)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.appending(path: name).path])
    }
}

/// Display-safe text for sender-controlled strings (subject, names, file names in lists):
/// bidi controls are removed so "rechnung\u{202E}fdp.exe" cannot pose as "rechnungexe.pdf";
/// line/paragraph separators, NBSP and filler characters become plain spaces and runs collapse,
/// so a name cannot hide its real end behind invisible padding. ZWJ/ZWNJ stay (emoji, scripts).
public enum DisplayText {
    public static func safe(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { isBidiControl($0) || isSpaceLike($0) || isRemovable($0) }) else { return s }
        return collapseWhitespace(normalizedScalars(s, dropFormat: false))
    }

    /// Removes control/bidi/private-use/unassigned/surrogate scalars, maps space-like ones to
    /// " ". `dropFormat` also removes all format characters (for file names).
    static func normalizedScalars(_ s: String, dropFormat: Bool) -> String {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.unicodeScalars.count)
        for c in s.unicodeScalars {
            if isSpaceLike(c) { out.append(" "); continue }
            if isBidiControl(c) || isRemovable(c) { continue }
            if dropFormat, c.properties.generalCategory == .format { continue }
            out.append(c)
        }
        return String(String.UnicodeScalarView(out))
    }

    static func isBidiControl(_ c: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(c.value) || (0x2066...0x2069).contains(c.value)
            || c.value == 0x200E || c.value == 0x200F || c.value == 0x061C
    }

    static func isSpaceLike(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return c != " "
        default: break
        }
        // blank-looking letters and symbols: Braille blank, Hangul fillers, CGJ
        return [0x2800, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x034F].contains(c.value)
    }

    static func isRemovable(_ c: Unicode.Scalar) -> Bool {
        if c.value == 0x09 || c.value == 0x0A { return false }  // collapse handles them
        switch c.properties.generalCategory {
        case .control, .privateUse, .unassigned, .surrogate: return true
        default: return false
        }
    }
}

/// MIME type → file name extension and risk, where UTType answers on macOS. The table holds
/// what macOS answers for the types mail carries (checked against UTType on macOS 27), so a
/// file gets the same name on both; risk is judged by the types that run, install or render.
enum MIMETypes {
    static func preferredExtension(for mimeType: String) -> String? {
        #if canImport(UniformTypeIdentifiers)
        UTType(mimeType: mimeType)?.preferredFilenameExtension
        #else
        extensions[essence(mimeType)]
        #endif
    }

    /// "Text/HTML; charset=utf-8" → "text/html".
    static func essence(_ mimeType: String) -> String {
        String(mimeType.split(separator: ";").first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    static let extensions: [String: String] = [
        "application/pdf": "pdf",
        "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/vnd.oasis.opendocument.text": "odt",
        "application/vnd.oasis.opendocument.spreadsheet": "ods",
        "application/vnd.oasis.opendocument.presentation": "odp",
        "text/rtf": "rtf", "text/plain": "txt", "text/csv": "csv", "text/calendar": "ics", "text/html": "html",
        "application/xml": "xml", "text/xml": "xml", "application/json": "json",
        "image/jpeg": "jpeg", "image/png": "png", "image/gif": "gif", "image/heic": "heic", "image/tiff": "tiff",
        "image/webp": "webp", "image/svg+xml": "svg", "image/bmp": "bmp",
        "application/zip": "zip", "application/gzip": "gz", "application/x-7z-compressed": "7z",
        "message/rfc822": "eml", "audio/mpeg": "mp3", "video/mp4": "mp4", "video/quicktime": "mov",
        "text/vcard": "vcf", "text/x-vcard": "vcf",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/mp4": "mp4", "audio/x-m4a": "m4a", "audio/aac": "aac",
        "audio/ogg": "ogg", "audio/flac": "flac", "text/markdown": "md", "image/heif": "heif",
        "image/vnd.microsoft.icon": "ico", "image/jpg": "jpeg", "application/x-zip-compressed": "zip",
        "application/x-rar-compressed": "rar", "application/x-tar": "tar", "application/x-bzip2": "bz2",
        "application/epub+zip": "epub", "video/mpeg": "mpg", "video/x-msvideo": "avi", "video/webm": "webm",
        "application/vnd.visio": "vsd", "text/tab-separated-values": "tsv", "application/x-x509-ca-cert": "cer",
        "application/postscript": "ps", "application/xhtml+xml": "xhtml", "text/x-vcalendar": "vcs",
    ]

    static let webTypes: Set<String> = [
        "text/html", "application/xhtml+xml", "image/svg+xml", "application/x-webarchive",
        "application/x-mswinurl", "message/external-body",
    ]

    /// Programs, scripts, installers, disk images, configuration profiles, macro documents.
    static let riskyTypes: Set<String> = [
        "application/x-msdownload", "application/x-msdos-program", "application/x-dosexec", "application/x-executable",
        "application/x-mach-binary", "application/x-elf", "application/x-sharedlib", "application/vnd.microsoft.portable-executable",
        "application/x-msi", "application/x-ms-installer", "application/vnd.ms-cab-compressed",
        "application/x-sh", "application/x-shellscript", "text/x-shellscript", "application/x-csh",
        "application/javascript", "text/javascript", "application/x-javascript", "application/ecmascript",
        "application/x-python", "text/x-python", "text/x-python-script", "application/x-perl", "text/x-perl",
        "text/x-perl-script", "application/x-ruby", "text/x-ruby-script", "application/x-php", "text/php",
        "text/x-php-script", "application/hta", "application/x-bat", "application/java-archive",
        "application/x-apple-diskimage", "application/x-iso9660-image", "application/vnd.apple.installer+xml",
        "application/x-apple-aspen-config", "application/x-xar",
    ]

    static func isWebContent(_ mimeType: String) -> Bool { webTypes.contains(essence(mimeType)) }

    static func isRisky(_ mimeType: String) -> Bool {
        let type = essence(mimeType)
        return riskyTypes.contains(type) || type.contains("macroenabled")
    }
}

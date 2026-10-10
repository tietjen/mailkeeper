import AppKit
import MailKeeperKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Attachments of the open message as chips: click = Quick Look, double-click = open,
/// context menu = preview / open / save. Risky files (programs, scripts, installers, disk
/// images, macro documents) can be previewed and saved, never opened from MailKeeper.
struct AttachmentBar: View {
    let message: ParsedMessage
    let attachments: [AttachmentInfo]
    @State private var previewURL: URL?
    @State private var errorText: String?

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                let name = AttachmentSafety.sanitizedFilename(attachment.filename, mimeType: attachment.mimeType)
                let risky = AttachmentSafety.isRisky(filename: name, mimeType: attachment.mimeType)
                AttachmentChip(name: name, mimeType: attachment.mimeType, size: attachment.size, risky: risky)
                    .onTapGesture(count: 2) { risky ? save(attachment, as: name) : open(attachment, as: name) }
                    .onTapGesture { preview(attachment, as: name) }
                    .contextMenu {
                        Button("Vorschau") { preview(attachment, as: name) }
                        Button("Öffnen") { open(attachment, as: name) }.disabled(risky)
                        Button("Sichern unter …") { save(attachment, as: name) }
                        if attachments.count > 1 {
                            Divider()
                            Button("Alle Anhänge sichern …") { saveAll() }
                        }
                    }
                    .help(risky
                        ? String(localized: "Programm, Skript, Installer oder Makro-Dokument: MailKeeper öffnet so etwas nicht. Vorschau und Sichern sind möglich.")
                        : String(localized: "Klick: Vorschau · Doppelklick: öffnen · Rechtsklick: sichern"))
            }
        }
        .quickLookPreview($previewURL)
        .alert("Anhang", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: Actions

    private func bytes(_ attachment: AttachmentInfo) async -> Data? {
        let message = self.message
        return await Task.detached(priority: .userInitiated) { message.data(of: attachment) }.value
    }

    private func preview(_ attachment: AttachmentInfo, as name: String) {
        Task {
            guard let data = await bytes(attachment) else { return fail() }
            do { previewURL = try AttachmentFiles.materialize(data, name: name) } catch { fail(error) }
        }
    }

    private func open(_ attachment: AttachmentInfo, as name: String) {
        guard !AttachmentSafety.isRisky(filename: name, mimeType: attachment.mimeType) else { return }
        Task {
            guard let data = await bytes(attachment) else { return fail() }
            do { NSWorkspace.shared.open(try AttachmentFiles.materialize(data, name: name)) } catch { fail(error) }
        }
    }

    private func save(_ attachment: AttachmentInfo, as name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let data = await bytes(attachment) else { return fail() }
            do { try AttachmentFiles.write(data, to: url) } catch { fail(error) }
        }
    }

    private func saveAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Hier sichern")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            for attachment in attachments {
                let name = AttachmentSafety.sanitizedFilename(attachment.filename, mimeType: attachment.mimeType)
                guard let data = await bytes(attachment) else { continue }
                do { try AttachmentFiles.write(data, to: AttachmentSafety.uniqueURL(in: dir, name: name)) } catch { fail(error) }
            }
        }
    }

    private func fail(_ error: Error? = nil) {
        errorText = error.map { "\($0.localizedDescription)" } ?? String(localized: "Der Anhang konnte nicht gelesen werden.")
    }
}

struct AttachmentChip: View {
    let name: String
    let mimeType: String
    let size: Int
    let risky: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if risky {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .contentShape(Rectangle())
    }

    private var icon: NSImage {
        let ext = (name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? UTType(mimeType: mimeType) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// Temporary copies for Quick Look and "open", private to the user and quarantined as mail
/// attachments, so Gatekeeper treats them like downloads. Removed at launch and quit.
@MainActor
enum AttachmentFiles {
    static let root = FileManager.default.temporaryDirectory.appending(path: "MailKeeper-Anhaenge", directoryHint: .isDirectory)

    static func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    static func materialize(_ data: Data, name: String) throws -> URL {
        let dir = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(root.path, 0o700)
        let url = dir.appending(path: name)
        try write(data, to: url)
        return url
    }

    static func write(_ data: Data, to url: URL) throws {
        try AttachmentSafety.writeQuarantined(data, to: url)
    }
}

/// Left-to-right flow layout that wraps to the next line.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var y: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if !current.items.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                y += current.height + spacing
                current = Row(y: y)
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(i)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

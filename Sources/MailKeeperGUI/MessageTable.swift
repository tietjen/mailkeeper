import AppKit
import MailKeeperKit
import SwiftUI

/// The message list (ADR-0007): a view-based NSTableView that pages rows from the index by id,
/// so 100k+ messages scroll at display rate. Sorting maps to SQL in the model.
struct MessageTable: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true  // Phase 4: act on several messages at once
        table.rowSizeStyle = .medium
        // Only "Von" and "Betreff" absorb width changes of the table; the others keep their width
        // (and stay user-resizable). Without minimum widths the uniform autoresizing squeezed the
        // date column to a few points and took back every manual resize.
        let columns: [(sort: MessageSort?, id: String, title: String, width: CGFloat, min: CGFloat, flexible: Bool)] = [
            (.date, "date", String(localized: "Datum"), 92, 72, false),
            (.from, "from", String(localized: "Von"), 210, 110, true),
            (.subject, "subject", String(localized: "Betreff"), 420, 180, true),
            (nil, "attach", "📎", 26, 26, false),
            (nil, "thread", "💬", 34, 34, false),
            (.size, "size", String(localized: "Größe"), 72, 56, false),
        ]
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.minWidth = c.min
            col.width = c.width
            if c.id == "attach" || c.id == "thread" {
                col.maxWidth = c.width
                col.resizingMask = []
                col.headerToolTip = c.id == "attach" ? String(localized: "Anhänge") : String(localized: "Nachrichten in der Konversation")
            } else {
                col.maxWidth = c.flexible ? 4000 : 400
                col.resizingMask = c.flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            }
            if let sort = c.sort { col.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: sort != .date) }
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle  // among flexible columns only
        table.autosaveName = "MailKeeper.MessageTable"  // remembers widths and order
        table.autosaveTableColumns = true
        table.sortDescriptors = [NSSortDescriptor(key: MessageSort.date.rawValue, ascending: false)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.syncIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var table: NSTableView?
        private var generation = -1
        private var selectionRequest = 0
        /// Set while the model drives the selection, so the delegate does not echo it back.
        private var applyingSelection = false
        private var ids: [Int64] = []
        private var pages: [Int: [MessageSummary]] = [:]
        private let pageSize = 200
        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            return f
        }()

        init(model: AppModel) {
            self.model = model
        }

        func syncIfNeeded() {
            let request = model.selectionRequest
            if generation != model.listGeneration {
                generation = model.listGeneration
                ids = model.messageIDs
                pages.removeAll()
                table?.reloadData()
                applySelection(scroll: false)
            }
            if selectionRequest != request {
                selectionRequest = request
                applySelection(scroll: true)
            }
        }

        /// Mirrors the model's selection; a message that is not listed deselects the table
        /// while the reader keeps showing it.
        private func applySelection(scroll: Bool) {
            guard let table else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            if let sel = model.selectedMessageID, let row = ids.firstIndex(of: sel) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                if scroll { table.scrollRowToVisible(row) }
            } else if model.selectedMessageID != nil {
                table.deselectAll(nil)
            }
        }

        private func summary(at row: Int) -> MessageSummary? {
            guard row >= 0, row < ids.count else { return nil }
            let page = row / pageSize
            if pages[page] == nil {
                let lo = page * pageSize, hi = min(ids.count, lo + pageSize)
                pages[page] = model.summaries(Array(ids[lo..<hi]))
                if pages.count > 300 { pages.removeValue(forKey: pages.keys.first { $0 != page }!) }
            }
            let rows = pages[page]!
            let i = row - page * pageSize
            return i < rows.count ? rows[i] : nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, let m = summary(at: row) else { return nil }
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView) ?? makeCell(column.identifier)
            let text: String
            switch column.identifier.rawValue {
            case "date": text = m.date.map { dateFormatter.string(from: $0) } ?? "—"
            case "from": text = m.fromDisplay
            case "subject": text = m.subject?.isEmpty == false ? m.subject! : String(localized: "(kein Betreff)")
            case "attach": text = m.attachmentCount > 0 ? "📎" : ""
            case "thread": text = m.threadCount > 1 ? "\(m.threadCount)" : ""
            case "size": text = ByteCountFormatter.string(fromByteCount: Int64(m.size), countStyle: .file)
            default: text = ""
            }
            cell.textField?.stringValue = DisplayText.safe(text)
            cell.toolTip = column.identifier.rawValue == "subject" ? m.snippet : nil
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            if id.rawValue == "size" { tf.alignment = .right }
            if id.rawValue == "thread" { tf.alignment = .center; tf.textColor = .secondaryLabelColor }
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, !applyingSelection else { return }
            let row = table.selectedRow
            model.selectedMessageIDs = Set(table.selectedRowIndexes.compactMap { $0 < ids.count ? ids[$0] : nil })
            model.selectedMessageID = row >= 0 && row < ids.count ? ids[row] : nil
        }

        // MARK: Context menu (Phase 4)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            // A right-click outside the selection acts on the clicked row, like Mail and Finder.
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes([clicked], byExtendingSelection: false)
            }
            guard !model.actionSelection.isEmpty else { return }
            let count = model.actionSelection.count
            if model.sidebarSelection == .trash {
                add(menu, count == 1 ? String(localized: "Wiederherstellen") : String(localized: "\(count) Mails wiederherstellen"), #selector(restore))
                add(menu, String(localized: "Endgültig löschen …"), #selector(purge))
                menu.addItem(.separator())
                add(menu, String(localized: "Exportieren …"), #selector(export))
            } else {
                add(menu, String(localized: "Auf dem Server löschen …"), #selector(deleteOnServer))
                add(menu, String(localized: "Aus dem Archiv löschen …"), #selector(deleteFromArchive))
                menu.addItem(.separator())
                add(menu, String(localized: "Auf den Server zurückspielen …"), #selector(restoreToServer))
                add(menu, String(localized: "Exportieren …"), #selector(export))
            }
        }

        private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        @objc private func deleteOnServer() { model.planSelection(.serverDelete) }
        @objc private func deleteFromArchive() { model.planSelection(.archiveDelete) }
        @objc private func restoreToServer() { model.planSelection(.restore) }
        @objc private func export() { model.exportSelection() }
        @objc private func restore() { model.restoreSelection() }
        @objc private func purge() { Task { await model.purgeSelection() } }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let d = tableView.sortDescriptors.first, let key = d.key.flatMap(MessageSort.init(rawValue:)) else { return }
            model.setSort(key, ascending: d.ascending)
        }
    }
}

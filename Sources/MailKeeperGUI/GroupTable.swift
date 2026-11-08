import AppKit
import MailKeeperKit
import SwiftUI

/// Cleanup view: groups of the current scope and search, sortable; double-click opens the
/// group's messages (its exact query is added to the search). An NSTableView like the message
/// list (ADR-0007): the SwiftUI `Table` measured every row through its own hosting view, and
/// "Zurück" into 2,000 groups hung the app for minutes (TJ, 2026-10-13). Fixed row height,
/// plain text cells.
struct GroupTable: View {
    let model: AppModel

    var body: some View {
        // the footer below the table, not as a safe-area inset (an NSTableView ignores it and
        // its last row would sit under the bar)
        VStack(spacing: 0) {
            GroupTableView(model: model)
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.bar)
        }
    }

    private var footer: String {
        let mails = model.groups.reduce(0) { $0 + $1.count }
        let bytes = model.groups.reduce(Int64(0)) { $0 + $1.bytes }
        let capped = model.groups.count >= 2_000 ? String(localized: " (die 2 000 größten)") : ""
        return String(localized: "\(model.groups.count.formatted()) Gruppen\(capped) · \(mails.formatted()) Mails · \(bytes.formatted(.byteCount(style: .file))) — Doppelklick zeigt die Mails einer Gruppe")
    }
}

private struct GroupTableView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 34  // two lines: name and address
        let columns: [(id: String, title: String, width: CGFloat, min: CGFloat, flexible: Bool, ascending: Bool)] = [
            ("name", String(localized: "Absender"), 280, 150, true, true),
            ("count", String(localized: "Mails"), 60, 50, false, false),
            ("bytes", String(localized: "Größe"), 75, 60, false, false),
            ("server", String(localized: "Server"), 60, 44, false, false),
            ("archive", String(localized: "Nur Archiv"), 80, 52, false, false),
            ("unread", String(localized: "Ungelesen"), 75, 60, false, false),
            ("newest", String(localized: "Neueste"), 85, 70, false, false),
            ("oldest", String(localized: "Älteste"), 85, 70, false, true),
            ("unsubscribe", "", 24, 24, false, false),
        ]
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.minWidth = c.min
            col.width = c.width
            switch c.id {
            case "server": col.headerToolTip = String(localized: "Davon noch auf einem Server")
            case "archive": col.headerToolTip = String(localized: "Davon auf keinem Server (dort gelöscht oder importiert)")
            default: break
            }
            if c.id == "unsubscribe" {
                col.maxWidth = c.width
                col.resizingMask = []
                col.headerToolTip = String(localized: "Bietet eine Abmeldung an (List-Unsubscribe)")
            } else {
                col.maxWidth = c.flexible ? 4000 : 300
                col.resizingMask = c.flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
                col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: c.ascending)
            }
            if c.id != "name" { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // a new name with new columns: the layout saved under the old one would leave them at the end
        table.autosaveName = "MailKeeper.GroupTable.2"
        table.autosaveTableColumns = true
        table.sortDescriptors = [NSSortDescriptor(key: "count", ascending: false)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // the columns' minimum widths add up to more than the narrowest middle pane: scroll
        // sideways rather than cut off "Neueste", "Älteste" and ✉︎ without a sign
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // read here, so SwiftUI calls again when they change
        context.coordinator.sync(groups: model.groups, selected: model.selectedGroupID, mode: model.viewMode)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var table: NSTableView?
        private var source: [MessageGroup] = []
        private var rows: [MessageGroup] = []
        private var selected: String?
        private var mode: ViewMode?
        /// Set while the model drives the selection, so the delegate does not echo it back.
        private var applyingSelection = false
        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            return f
        }()

        init(model: AppModel) {
            self.model = model
        }

        func sync(groups: [MessageGroup], selected: String?, mode: ViewMode) {
            guard let table else { return }
            if mode != self.mode {
                self.mode = mode
                table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))?.title = switch mode {
                case .domain: String(localized: "Domain")
                case .list: String(localized: "Liste")
                default: String(localized: "Absender")
                }
            }
            let reloaded = groups != source
            if reloaded {
                source = groups
                rows = sorted(groups)
                reload(table)
            }
            let moved = selected != self.selected
            self.selected = selected
            // after a reload the table keeps row numbers, not groups: always select again; scroll
            // only when the selection itself moved (a background refresh keeps the scroll position)
            if reloaded || moved { applySelection(scroll: moved) }
        }

        private func sorted(_ groups: [MessageGroup]) -> [MessageGroup] {
            guard let d = table?.sortDescriptors.first, let key = d.key else { return groups }
            let asc = d.ascending
            func order<T: Comparable>(_ a: T, _ b: T, _ ta: MessageGroup, _ tb: MessageGroup) -> Bool {
                a == b ? ta.count > tb.count : (asc ? a < b : a > b)  // ties: the bigger group first
            }
            return groups.sorted { a, b in
                switch key {
                case "name": order(a.displaySort, b.displaySort, a, b)
                case "bytes": order(a.bytes, b.bytes, a, b)
                case "server": order(a.onServer, b.onServer, a, b)
                case "archive": order(a.archiveOnly, b.archiveOnly, a, b)
                case "unread": order(a.unreadShare, b.unreadShare, a, b)
                case "newest": order(a.newestSort, b.newestSort, a, b)
                case "oldest": order(a.oldestSort, b.oldestSort, a, b)
                default: a.count == b.count ? a.key < b.key : (asc ? a.count < b.count : a.count > b.count)
                }
            }
        }

        /// Mirrors the model's selection and brings it into view (a suggestion's "Zur Gruppe",
        /// "Zurück").
        private func applySelection(scroll: Bool) {
            guard let table else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            if let id = selected, let row = rows.firstIndex(where: { $0.id == id }) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                if scroll { table.scrollRowToVisible(row) }
            } else {
                table.deselectAll(nil)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, row < rows.count else { return nil }
            let g = rows[row]
            let id = column.identifier
            if id.rawValue == "name" {
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? GroupNameCell) ?? GroupNameCell(identifier: id)
                cell.title.stringValue = DisplayText.safe(g.name ?? g.key)
                cell.subtitle.stringValue = g.name != nil ? DisplayText.safe(g.key) : ""
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
            cell.textField?.textColor = .labelColor
            cell.toolTip = nil
            switch id.rawValue {
            case "count": cell.textField?.stringValue = g.count.formatted()
            case "bytes": cell.textField?.stringValue = g.bytes.formatted(.byteCount(style: .file))
            case "server": cell.textField?.stringValue = g.onServer.formatted()
            case "archive": cell.textField?.stringValue = g.archiveOnly.formatted()
            case "unread":
                cell.textField?.stringValue = g.unreadShare.formatted(.percent.precision(.fractionLength(0)))
                if g.unreadShare > 0.9 && g.count >= 10 { cell.textField?.textColor = .systemOrange }
            case "newest": cell.textField?.stringValue = g.newest.map { dateFormatter.string(from: $0) } ?? "—"
            case "oldest": cell.textField?.stringValue = g.oldest.map { dateFormatter.string(from: $0) } ?? "—"
            case "unsubscribe":
                cell.textField?.stringValue = g.unsubscribe ? "✉︎" : ""
                cell.textField?.textColor = .secondaryLabelColor
                cell.toolTip = g.unsubscribe ? String(localized: "Bietet eine Abmeldung an (List-Unsubscribe)") : nil
            default: cell.textField?.stringValue = ""
            }
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.alignment = id.rawValue == "unsubscribe" ? .center : .right
            if id.rawValue != "unsubscribe" { tf.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
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
            let id = row >= 0 && row < rows.count ? rows[row].id : nil
            selected = id
            model.selectedGroupID = id
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            rows = sorted(source)
            reload(tableView)
            applySelection(scroll: true)
        }

        /// AppKit may trim the selection to the new rows and say so — that must not reach the
        /// model in the middle of a SwiftUI update (review 6.6 S6); the selection is set again after.
        private func reload(_ table: NSTableView) {
            applyingSelection = true
            defer { applyingSelection = false }
            table.reloadData()
        }

        @objc func openClicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            model.openGroup(rows[table.clickedRow])
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            let open = NSMenuItem(title: String(localized: "Mails anzeigen"), action: #selector(openClicked), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let copy = NSMenuItem(title: String(localized: "Suche kopieren"), action: #selector(copyQuery), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }

        @objc private func copyQuery() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rows[table.clickedRow].query, forType: .string)
        }
    }
}

/// Name over address, both truncated — the row height stays the same for every group.
private final class GroupNameCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        for field in [title, subtitle] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        addSubview(stack)
        textField = title
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

extension MessageGroup {
    var unreadShare: Double { count > 0 ? Double(unread) / Double(count) : 0 }
    var newestSort: Date { newest ?? .distantPast }
    var oldestSort: Date { oldest ?? .distantPast }
    var displaySort: String { (name ?? key).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}

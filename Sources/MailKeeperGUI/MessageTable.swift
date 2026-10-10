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
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .medium
        let columns: [(MessageSort?, String, String, CGFloat)] = [
            (.date, "date", String(localized: "Datum"), 96),
            (.from, "from", String(localized: "Von"), 210),
            (.subject, "subject", String(localized: "Betreff"), 420),
            (nil, "attach", "📎", 26),
            (.size, "size", String(localized: "Größe"), 70),
        ]
        for (sort, id, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            if let sort { col.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: sort != .date) }
            table.addTableColumn(col)
        }
        table.sortDescriptors = [NSSortDescriptor(key: MessageSort.date.rawValue, ascending: false)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AppModel
        weak var table: NSTableView?
        private var generation = -1
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
            guard generation != model.listGeneration else { return }
            generation = model.listGeneration
            ids = model.messageIDs
            pages.removeAll()
            table?.reloadData()
            if let sel = model.selectedMessageID, let row = ids.firstIndex(of: sel) {
                table?.selectRowIndexes([row], byExtendingSelection: false)
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
            case "size": text = ByteCountFormatter.string(fromByteCount: Int64(m.size), countStyle: .file)
            default: text = ""
            }
            cell.textField?.stringValue = text
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
            guard let table else { return }
            let row = table.selectedRow
            model.selectedMessageID = row >= 0 && row < ids.count ? ids[row] : nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let d = tableView.sortDescriptors.first, let key = d.key.flatMap(MessageSort.init(rawValue:)) else { return }
            model.setSort(key, ascending: d.ascending)
        }
    }
}

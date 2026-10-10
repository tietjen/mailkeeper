import AppKit
import Observation
import SwiftUI

protocol BenchTarget: AnyObject {
    var rowCount: Int { get }
    func applySort(_ key: SortKey, ascending: Bool)
    func selectAll()
    func setFilter(_ text: String?)
}

private func sortKey<T>(_ comparator: KeyPathComparator<T>?, map: [PartialKeyPath<T>: SortKey]) -> (SortKey, Bool)? {
    guard let c = comparator, let key = map[c.keyPath] else { return nil }
    return (key, c.order == .forward)
}

// MARK: - A: SwiftUI Table over [RowData]

@Observable final class ArrayModel: BenchTarget {
    let store: Store
    var rows: [RowData] = []
    var selection = Set<Int64>()
    var sortOrder: [KeyPathComparator<RowData>] = [KeyPathComparator(\RowData.date, order: .reverse)]
    static let keys: [PartialKeyPath<RowData>: SortKey] =
        [\RowData.date: .date, \RowData.sender: .sender, \RowData.subject: .subject, \RowData.size: .size, \RowData.account: .account]

    init(store: Store) {
        self.store = store
        rows = store.loadAll()
    }

    var rowCount: Int { rows.count }

    func sortOrderChanged() {
        guard let (key, asc) = sortKey(sortOrder.first, map: Self.keys) else { return }
        store.sortKey = key
        store.ascending = asc
        rows = store.loadAll()
    }

    func applySort(_ key: SortKey, ascending: Bool) {
        let kp = Self.keys.first { $0.value == key }!.key
        sortOrder = [comparator(kp, ascending)]
    }

    private func comparator(_ kp: PartialKeyPath<RowData>, _ asc: Bool) -> KeyPathComparator<RowData> {
        let order: SortOrder = asc ? .forward : .reverse
        switch kp {
        case \RowData.sender: return KeyPathComparator(\RowData.sender, order: order)
        case \RowData.subject: return KeyPathComparator(\RowData.subject, order: order)
        case \RowData.size: return KeyPathComparator(\RowData.size, order: order)
        case \RowData.account: return KeyPathComparator(\RowData.account, order: order)
        default: return KeyPathComparator(\RowData.date, order: order)
        }
    }

    func selectAll() { selection = Set(rows.map(\.id)) }

    func setFilter(_ text: String?) {
        store.filter = text
        rows = store.loadAll()
    }
}

struct ArrayTableView: View {
    @Bindable var model: ArrayModel

    var body: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Datum", value: \RowData.date) { Text($0.date, format: .dateTime.year().month().day()) }
                .width(110)
            TableColumn("Von", value: \RowData.sender)
            TableColumn("Betreff", value: \RowData.subject)
            TableColumn("Größe", value: \RowData.size) { Text($0.size.formatted(.byteCount(style: .file))) }
                .width(80)
            TableColumn("Konto", value: \RowData.account).width(90)
        }
        .onChange(of: model.sortOrder) { model.sortOrderChanged() }
    }
}

// MARK: - B: SwiftUI Table over a lazy collection (ids in memory, rows from a page cache)

struct RowRef: Identifiable, Hashable {
    let id: Int64
    let index: Int
    unowned let store: Store

    static func == (a: RowRef, b: RowRef) -> Bool { a.id == b.id && a.index == b.index }
    func hash(into h: inout Hasher) { h.combine(id) }

    var data: RowData { store.row(at: index) }
    var date: Date { data.date }
    var sender: String { data.sender }
    var subject: String { data.subject }
    var size: Int { data.size }
    var account: String { data.account }
}

struct LazyRows: RandomAccessCollection {
    let ids: [Int64]
    unowned let store: Store
    var startIndex: Int { 0 }
    var endIndex: Int { ids.count }
    subscript(i: Int) -> RowRef { RowRef(id: ids[i], index: i, store: store) }
}

@Observable final class LazyModel: BenchTarget {
    let store: Store
    var rows: LazyRows
    var selection = Set<Int64>()
    var sortOrder: [KeyPathComparator<RowRef>] = [KeyPathComparator(\RowRef.date, order: .reverse)]
    static let keys: [PartialKeyPath<RowRef>: SortKey] =
        [\RowRef.date: .date, \RowRef.sender: .sender, \RowRef.subject: .subject, \RowRef.size: .size, \RowRef.account: .account]

    init(store: Store) {
        self.store = store
        store.reloadIDs()
        rows = LazyRows(ids: store.ids, store: store)
    }

    var rowCount: Int { rows.count }

    func sortOrderChanged() {
        guard let (key, asc) = sortKey(sortOrder.first, map: Self.keys) else { return }
        store.sortKey = key
        store.ascending = asc
        store.reloadIDs()
        rows = LazyRows(ids: store.ids, store: store)
    }

    func applySort(_ key: SortKey, ascending: Bool) {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case .date: sortOrder = [KeyPathComparator(\RowRef.date, order: order)]
        case .sender: sortOrder = [KeyPathComparator(\RowRef.sender, order: order)]
        case .subject: sortOrder = [KeyPathComparator(\RowRef.subject, order: order)]
        case .size: sortOrder = [KeyPathComparator(\RowRef.size, order: order)]
        case .account: sortOrder = [KeyPathComparator(\RowRef.account, order: order)]
        }
    }

    func selectAll() { selection = Set(rows.ids) }

    func setFilter(_ text: String?) {
        store.filter = text
        store.reloadIDs()
        rows = LazyRows(ids: store.ids, store: store)
    }
}

struct LazyTableView: View {
    @Bindable var model: LazyModel

    var body: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Datum", value: \RowRef.date) { Text($0.date, format: .dateTime.year().month().day()) }
                .width(110)
            TableColumn("Von", value: \RowRef.sender) { Text($0.sender) }
            TableColumn("Betreff", value: \RowRef.subject) { Text($0.subject) }
            TableColumn("Größe", value: \RowRef.size) { Text($0.size.formatted(.byteCount(style: .file))) }
                .width(80)
            TableColumn("Konto", value: \RowRef.account) { Text($0.account) }.width(90)
        }
        .onChange(of: model.sortOrder) { model.sortOrderChanged() }
    }
}

// MARK: - C: NSTableView (view-based, cell reuse) inside SwiftUI

final class AppKitModel: NSObject, BenchTarget, NSTableViewDataSource, NSTableViewDelegate {
    let store: Store
    weak var tableView: NSTableView?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
    private let sizeFormatter = ByteCountFormatter()

    init(store: Store) {
        self.store = store
        store.reloadIDs()
    }

    var rowCount: Int { store.ids.count }

    func numberOfRows(in tableView: NSTableView) -> Int { store.ids.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = column.identifier
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let r = store.row(at: row)
        switch SortKey(rawValue: column.identifier.rawValue) {
        case .date: cell.textField?.stringValue = dateFormatter.string(from: r.date)
        case .sender: cell.textField?.stringValue = r.sender
        case .subject: cell.textField?.stringValue = r.subject
        case .size: cell.textField?.stringValue = sizeFormatter.string(fromByteCount: Int64(r.size))
        case .account: cell.textField?.stringValue = r.account
        case nil: break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key.flatMap(SortKey.init(rawValue:)) else { return }
        store.sortKey = key
        store.ascending = d.ascending
        store.reloadIDs()
        tableView.reloadData()
    }

    func applySort(_ key: SortKey, ascending: Bool) {
        tableView?.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: ascending)]
    }

    func selectAll() { tableView?.selectAll(nil) }

    func setFilter(_ text: String?) {
        store.filter = text
        store.reloadIDs()
        tableView?.reloadData()
    }
}

struct AppKitTableView: NSViewRepresentable {
    let model: AppKitModel

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        let columns: [(SortKey, String, CGFloat)] =
            [(.date, "Datum", 110), (.sender, "Von", 220), (.subject, "Betreff", 480), (.size, "Größe", 80), (.account, "Konto", 90)]
        for (key, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            col.title = title
            col.width = width
            col.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            table.addTableColumn(col)
        }
        table.dataSource = model
        table.delegate = model
        model.tableView = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

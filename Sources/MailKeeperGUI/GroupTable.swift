import MailKeeperKit
import SwiftUI

/// Cleanup view: groups of the current scope and search, sortable; double-click opens the
/// group's messages (its exact query is added to the search).
struct GroupTable: View {
    let model: AppModel
    @State private var sortOrder = [KeyPathComparator(\MessageGroup.count, order: .reverse)]

    var body: some View {
        let selection = Binding<MessageGroup.ID?>(get: { model.selectedGroupID }, set: { model.selectedGroupID = $0 })
        Table(model.groups.sorted(using: sortOrder), selection: selection, sortOrder: $sortOrder) {
            TableColumn(title, value: \.displaySort) { g in  // by what is shown: the name, else the key
                VStack(alignment: .leading, spacing: 1) {
                    Text(DisplayText.safe(g.name ?? g.key)).lineLimit(1)
                    if g.name != nil {
                        Text(DisplayText.safe(g.key)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Mails", value: \.count) { g in
                Text(g.count.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Größe", value: \.bytes) { g in
                Text(g.bytes.formatted(.byteCount(style: .file))).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 75)
            TableColumn("Ungelesen", value: \.unreadShare) { g in
                Text(g.unreadShare.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(g.unreadShare > 0.9 && g.count >= 10 ? .orange : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 75)
            TableColumn("Neueste", value: \.newestSort) { g in
                Text(g.newest.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—").monospacedDigit()
            }
            .width(min: 70, ideal: 85)
            TableColumn("Älteste", value: \.oldestSort) { g in
                Text(g.oldest.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—").monospacedDigit()
            }
            .width(min: 70, ideal: 85)
            TableColumn("") { g in
                if g.unsubscribe {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .foregroundStyle(.secondary)
                        .help("Bietet eine Abmeldung an (List-Unsubscribe)")
                }
            }
            .width(24)
        }
        .contextMenu(forSelectionType: MessageGroup.ID.self) { ids in
            if let g = group(ids.first) {
                Button("Mails anzeigen") { model.openGroup(g) }
                Button("Suche kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(g.query, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let g = group(ids.first) { model.openGroup(g) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.bar)
        }
    }

    private var title: String {
        switch model.viewMode {
        case .domain: String(localized: "Domain")
        case .list: String(localized: "Liste")
        default: String(localized: "Absender")
        }
    }

    private var footer: String {
        let mails = model.groups.reduce(0) { $0 + $1.count }
        let bytes = model.groups.reduce(Int64(0)) { $0 + $1.bytes }
        let capped = model.groups.count >= 2_000 ? String(localized: " (die 2 000 größten)") : ""
        return String(localized: "\(model.groups.count.formatted()) Gruppen\(capped) · \(mails.formatted()) Mails · \(bytes.formatted(.byteCount(style: .file))) — Doppelklick zeigt die Mails einer Gruppe")
    }

    private func group(_ id: MessageGroup.ID?) -> MessageGroup? {
        model.groups.first { $0.id == id }
    }
}

extension MessageGroup {
    var unreadShare: Double { count > 0 ? Double(unread) / Double(count) : 0 }
    var newestSort: Date { newest ?? .distantPast }
    var oldestSort: Date { oldest ?? .distantPast }
    var displaySort: String { (name ?? key).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}

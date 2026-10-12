import AppKit
import MailKeeperKit
import SwiftUI

/// Cleanup view, right-hand pane for one group: what helps decide what to do with a sender,
/// a domain or a list — how much, how often, read or not, where it lives, what it is.
struct GroupDetailView: View {
    let model: AppModel
    let detail: GroupDetail
    @State private var saving: SavedSearch?
    @State private var confirmingUnsubscribe = false
    @State private var ruleDraft: RuleDraft?

    private var group: MessageGroup { detail.group }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metrics
                activity
                facts
                if !detail.members.isEmpty { members }
                recent
                actions
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .sheet(item: $saving) { SavedSearchSheet(model: model, search: $0) }
        .sheet(item: $ruleDraft) { d in RuleEditor(model: model, draft: d) { _ in ruleDraft = nil } }
        .confirmationDialog(unsubscribeTitle, isPresented: $confirmingUnsubscribe, titleVisibility: .visible) {
            if let https = detail.unsubscribe?.https {
                Button("Abmeldeseite im Browser öffnen") { NSWorkspace.shared.open(https) }
            }
            if let mailto = detail.unsubscribe?.mailto {
                Button("Abmelde-Mail vorbereiten") { NSWorkspace.shared.open(mailto) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(unsubscribeMessage)
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayText.safe(detail.listDescription ?? group.name ?? group.key)).font(.title3.weight(.semibold)).lineLimit(2)
                Text("\(DisplayText.safe(group.key)) · \(kind)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .textSelection(.enabled)
                if group.mode == .list, let sender = group.name, sender != detail.listDescription {
                    Text("zuletzt von \(DisplayText.safe(sender))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var metrics: some View {
        let readShare = group.count > 0 ? Double(detail.read) / Double(group.count) : 0
        let since = group.oldest.map { String(Calendar.current.component(.year, from: $0)) } ?? "—"
        return HStack(spacing: 8) {
            tile("Mails", group.count.formatted())
            tile("Größe", group.bytes.formatted(.byteCount(style: .file)))
            tile("Gelesen", readShare.formatted(.percent.precision(.fractionLength(0))))
            tile("Seit", since)
        }
    }

    private func tile(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
    }

    private var activity: some View {
        let peak = max(1, detail.months.map(\.count).max() ?? 1)
        let monthly = Double(detail.lastYear) / 12
        return VStack(alignment: .leading, spacing: 6) {
            Text(activityCaption(monthly)).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(detail.months.enumerated()), id: \.offset) { index, m in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index == detail.months.count - 1 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.45)))
                        .frame(height: max(2, 44 * CGFloat(m.count) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                        .help("\(m.month.formatted(.dateTime.month(.wide).year())): \(m.count)")
                }
            }
            .frame(height: 44, alignment: .bottom)
        }
    }

    private func activityCaption(_ monthly: Double) -> String {
        var parts = [String(localized: "Verlauf (24 Monate)")]
        if detail.lastYear == 0 {
            parts.append(String(localized: "im letzten Jahr nichts"))
        } else if monthly >= 1 {
            parts.append(String(localized: "etwa \(Int(monthly.rounded())) pro Monat"))
        } else {
            parts.append(String(localized: "\(detail.lastYear) im letzten Jahr"))
        }
        if let newest = group.newest {
            parts.append(String(localized: "zuletzt \(newest.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            fact("Ablage", detail.places.map { "\(DisplayText.safe($0.mailbox)) \($0.count.formatted())" }.joined(separator: " · "))
            fact("Auf dem Server", String(localized: "\(detail.onServer.formatted()) (\(detail.onServerBytes.formatted(.byteCount(style: .file)))) · nur im Archiv \((group.count - detail.onServer).formatted())"))
            fact("Mit Anhang", detail.withAttachments == 0 ? String(localized: "keine")
                 : String(localized: "\(detail.withAttachments.formatted()) · größte Mail \(detail.largest.formatted(.byteCount(style: .file)))"))
            if let target = detail.unsubscribe?.preferred {
                GridRow {
                    Text("Abmeldung").foregroundStyle(.secondary)
                    Text(DisplayText.safe(describe(target))).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .padding(.top, 4)
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2)
        }
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.mode == .domain ? "Absender dieser Domain" : "Absender in dieser Liste").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(detail.members, id: \.address) { m in
                    Button { model.showSender(m.address) } label: {
                        HStack {
                            Text(DisplayText.safe(m.name ?? m.address)).lineLimit(1)
                            if m.name != nil { Text(DisplayText.safe(m.address)).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Text(m.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Zu diesem Absender")
                }
            }
            .font(.callout)
            .background(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Neueste Mails").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(detail.recent) { m in
                    Button { model.openMessage(m.id, of: group) } label: {
                        HStack(spacing: 10) {
                            Text(m.date.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(DisplayText.safe(m.subject ?? String(localized: "(kein Betreff)"))).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("In der Nachrichtenliste öffnen")
                }
            }
            .font(.callout)
            .background(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Mails anzeigen") { model.openGroup(group) }
            Button("Als Ansicht sichern …") { saving = model.savedSearch(for: group) }
            if detail.unsubscribe != nil {
                Button("Abmelden …") { confirmingUnsubscribe = true }
            }
            Menu("Aufräumen …") {
                Button("Auf dem Server löschen …") { model.planGroup(.serverDelete, group) }
                Button("Aus dem Archiv löschen …") { model.planGroup(.archiveDelete, group) }
            }
            .fixedSize()
            .disabled(model.actionRunning)
            .help("Alle Mails dieser Gruppe – mit Plan und Rückfrage")
            Button("Regel …") { ruleDraft = RuleDraft(query: group.query, name: group.name ?? group.key) }
                .help("Für diese Gruppe künftig: Art festlegen, nach Tagen vom Server löschen oder in den Spam-Ordner")
        }
        .controlSize(.regular)
    }

    // MARK: Unsubscribe (variant 2: open after confirmation, https and mailto only)

    private var unsubscribeTitle: String {
        String(localized: "Von „\(DisplayText.safe(group.name ?? group.key))“ abmelden?")
    }

    private var unsubscribeMessage: String {
        var lines: [String] = []
        if let https = detail.unsubscribe?.https { lines.append(String(localized: "Seite: \(DisplayText.safe(describe(https)))")) }
        if let mailto = detail.unsubscribe?.mailto { lines.append(String(localized: "Mail an: \(DisplayText.safe(describe(mailto)))")) }
        lines.append(String(localized: "MailKeeper öffnet das Ziel nur. Bei Spam bestätigt eine Abmeldung dem Absender, dass deine Adresse existiert — dann lieber löschen als abmelden."))
        return lines.joined(separator: "\n\n")
    }

    /// Host and path for https (the host is what matters), the address for mailto.
    private func describe(_ url: URL) -> String {
        if url.scheme?.lowercased() == "mailto" {
            return String(url.absoluteString.dropFirst("mailto:".count).prefix { $0 != "?" })
        }
        let path = url.path.count > 40 ? String(url.path.prefix(40)) + "…" : url.path
        return (url.host ?? "") + path
    }

    private var icon: String {
        switch group.mode {
        case .sender: "person"
        case .domain: "globe"
        case .list: "newspaper"
        }
    }

    private var kind: String {
        switch group.mode {
        case .sender: String(localized: "Absender")
        case .domain: String(localized: "Domain")
        case .list: String(localized: "Mailingliste")
        }
    }
}

/// Cleanup view without a selection: where cleaning up pays off in the current scope.
struct CleanupOverviewView: View {
    let model: AppModel
    @State private var ruleDraft: RuleDraft?
    @State private var ruleMessage: String?

    /// 6.5b: destructive rules with mails ready, and rules suggested from repeated decisions.
    @ViewBuilder private var ruleCards: some View {
        let ready = model.mailRules.filter { $0.active && $0.action.isDestructive && (model.ruleReady[$0.id] ?? 0) > 0 }
        if !ready.isEmpty || !model.ruleSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Regeln").font(.headline)
                ForEach(ready) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DisplayText.safe(r.name)).fontWeight(.semibold)
                            Text("\(model.ruleReady[r.id] ?? 0) Mails bereit · \(r.action.label)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ausführen …") { model.runRule(r) }.controlSize(.small).disabled(model.actionRunning)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                }
                ForEach(model.ruleSuggestions.prefix(3)) { s in
                    RuleSuggestionRow(model: model, suggestion: s, edit: { ruleDraft = RuleDraft(s) }, message: $ruleMessage)
                }
                if model.ruleSuggestions.count > 3 {
                    Text("Weitere Vorschläge: Einstellungen › Regeln").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 6.5a: what MailKeeper suggests, archive-wide — counts, a reason, and the usual plan sheet.
    @ViewBuilder private var suggestions: some View {
        if model.loadingSuggestions && model.cleanupSuggestions.isEmpty {
            HStack { ProgressView().controlSize(.small); Text("Vorschläge werden berechnet …").foregroundStyle(.secondary) }
        } else if !model.cleanupSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vorschläge").font(.headline)
                ForEach(model.cleanupSuggestions) { s in suggestionCard(s) }
            }
        }
    }

    private func suggestionCard(_ s: CleanupSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(DisplayText.safe(s.title)).fontWeight(.semibold)
                Spacer()
                Text("\(s.count.formatted()) · \(s.bytes.formatted(.byteCount(style: .file)))").monospacedDigit().foregroundStyle(.secondary)
            }
            Text(DisplayText.safe(s.reason)).foregroundStyle(.secondary).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button("Ansehen") { model.showSuggestion(s) }
                if s.group != nil { Button("Zur Gruppe") { model.openSuggestionGroup(s) }.help("Details und Abmelden") }
                if s.onServer > 0 {
                    Button("Vom Server löschen …") { model.planSuggestion(s, .serverDelete) }
                        .help("\(s.onServer) Mails in den Papierkorb ihres Servers – das Archiv behält sie; vorher kommt die Übersicht")
                }
                if s.archiveOnly > 0 {
                    Button("Aus dem Archiv löschen …") { model.planSuggestion(s, .archiveDelete) }
                        .help("\(s.archiveOnly) Mails, die auf keinem Server mehr liegen, in den Papierkorb des Archivs – nach 30 Tagen endgültig weg; vorher kommt die Übersicht")
                }
            }
            .controlSize(.small)
            .disabled(model.actionRunning)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }

    /// Active: tinted with a check mark. Empty: shown, but nothing to click (choosing it would
    /// only leave nothing).
    @ViewBuilder private func bucketRow(_ b: CleanupOverview.Bucket) -> some View {
        let active = model.isBucketActive(b.query)
        let row = HStack {
            Image(systemName: "checkmark").foregroundStyle(.tint).opacity(active ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.title)
                Text(b.query).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(b.count == 0 ? String(localized: "keine") : b.count.formatted()).monospacedDigit()
                if b.count > 0 {
                    Text(b.bytes.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(active ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        if b.count == 0 && !active {
            row.foregroundStyle(.tertiary).help("Nichts in dieser Ansicht")
        } else {
            Button { model.toggleBucket(b) } label: { row }
                .buttonStyle(.plain)
                .help(active ? String(localized: "Eingrenzung aufheben") : String(localized: "Gruppen auf diese Mails eingrenzen"))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aufräumen").font(.title3.weight(.semibold))
                    if let total = model.cleanupOverview?.total {
                        Text("\(total.count.formatted()) Mails · \(total.bytes.formatted(.byteCount(style: .file))) in dieser Ansicht")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Wähle links eine Gruppe für Details. Ein Bereich grenzt die Gruppen ein; es ist immer nur einer aktiv, ein zweiter Klick hebt ihn auf.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ruleCards
                suggestions
                if let buckets = model.cleanupOverview?.buckets {
                    VStack(spacing: 0) {
                        ForEach(buckets, id: \.query) { b in bucketRow(b) }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    if buckets.contains(where: { model.isBucketActive($0.query) }) {
                        Button("Eingrenzung aufheben") { model.clearBuckets() }.buttonStyle(.link)
                    }
                }
                let biggest = model.groups.sorted { $0.bytes > $1.bytes }.prefix(5)
                if !biggest.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Größte Gruppen nach Speicher").font(.callout).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(biggest)) { g in
                                Button { model.selectedGroupID = g.id } label: {
                                    HStack {
                                        Text(DisplayText.safe(g.name ?? g.key)).lineLimit(1)
                                        Spacer()
                                        Text(g.bytes.formatted(.byteCount(style: .file))).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    }
                }
            }
            .font(.callout)
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .onAppear { model.reloadSuggestions(); model.reloadRules() }
        .sheet(item: $ruleDraft) { d in RuleEditor(model: model, draft: d) { _ in ruleDraft = nil } }
    }
}

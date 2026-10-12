import MailKeeperKit
import SwiftUI

/// Settings › Beziehungen (6.3, ADR-0010 §6): the organisations you really deal with and the
/// domains they really used — confirmed by you, suggested from your history.
struct RelationSettings: View {
    let model: AppModel
    @State private var show = Section.suggested
    @State private var selection: Set<String> = []
    @State private var draft: RelationDraft?
    @State private var message: String?
    @State private var newPublic = ""

    private func addPublic() {
        let address = newPublic
        Task {
            message = await model.addPublicAddress(address)
            if message == nil { newPublic = "" }
        }
    }

    enum Section: String, CaseIterable, Identifiable {
        case confirmed, suggested, rejected
        var id: String { rawValue }
    }

    private var confirmed: [Relation] { model.relations.filter(\.confirmed).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var rejected: [Relation] { model.relations.filter { !$0.confirmed && $0.rejected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Banken, Händler, Schulen, Partner – mit den Domains, von denen sie dir wirklich geschrieben haben. Gibt sich eine Mail als eine davon aus, kommt aber von einer anderen Domain, warnt MailKeeper. Vorschläge entstehen nur aus Belegen: du hast dorthin geschrieben, „Kein Spam“ gesagt oder eine Art festgelegt, oder echte Rechnungen und Bestellungen kamen mit bestandener Prüfung deines Servers.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $show) {
                Text("Bestätigt (\(confirmed.count))").tag(Section.confirmed)
                Text(model.loadingRelations ? "Vorschläge …" : "Vorschläge (\(model.relationSuggestions.count))").tag(Section.suggested)
                Text("Abgelehnt (\(rejected.count))").tag(Section.rejected)
            }
            .pickerStyle(.segmented).labelsHidden()
            switch show {
            case .confirmed: confirmedTable
            case .suggested: suggestionTable
            case .rejected: rejectedTable
            }
            HStack {
                Button("Neue Beziehung …") { draft = RelationDraft() }
                Spacer()
                Button("Vorschläge neu berechnen") { model.reloadRelations() }.disabled(model.loadingRelations)
            }
            Divider()
            // ADR-0010 §6: the bait address — a first contact there is unsolicited, not spam
            HStack(alignment: .firstTextBaseline) {
                Text("Öffentliche Adressen").fontWeight(.medium)
                    .help("Adressen, die auf deiner Webseite oder in Profilen stehen: Erstkontakte dort sind unaufgefordert – persönliche Angaben darin beweisen nichts")
                ForEach(model.publicAddressItems) { item in
                    HStack(spacing: 2) {
                        Text(item.subject.dropFirst("public:".count))
                        Button { Task { message = await model.forgetMemory([item.id]) } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                TextField("kontakt@deine-webseite.de", text: $newPublic).frame(maxWidth: 220)
                    .onSubmit(addPublic)
                Button("Hinzufügen", action: addPublic).disabled(newPublic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message { Text(DisplayText.safe(message)).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { model.reloadRelations() }
        .sheet(item: $draft) { d in
            RelationEditor(model: model, draft: d) { problem in
                message = problem
                draft = nil
            }
        }
    }

    private var confirmedTable: some View {
        Table(confirmed, selection: $selection) {
            TableColumn("Name") { r in Text(DisplayText.safe(r.name)).fontWeight(r.ended ? .regular : .medium).foregroundStyle(r.ended ? .secondary : .primary) }
                .width(min: 140, ideal: 200)
            TableColumn("Domains") { r in Text(r.domains.joined(separator: ", ")).lineLimit(2).help(r.domains.joined(separator: "\n")) }
                .width(min: 160, ideal: 240)
            TableColumn("Seit") { r in Text(r.since.map { $0.formatted(.dateTime.year().month()) } ?? "—").monospacedDigit() }.width(70)
            TableColumn("Bis") { r in Text(r.until.map { $0.formatted(.dateTime.year().month()) } ?? "läuft").monospacedDigit() }.width(70)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let r = confirmed.first(where: { $0.id == ids.first }) {
                Button("Bearbeiten …") { draft = RelationDraft(r) }
                if !r.ended {
                    Button("Beziehung beendet") {
                        Task { message = await model.saveRelation(id: r.id, name: r.name, domains: r.domains, since: r.since, until: .now) }
                    }
                }
                Button("Vergessen") { Task { message = await model.forgetRelation(r.id) } }
            }
        } primaryAction: { ids in
            if ids.count == 1, let r = confirmed.first(where: { $0.id == ids.first }) { draft = RelationDraft(r) }
        }
    }

    private var suggestionTable: some View {
        Table(model.relationSuggestions, selection: $selection) {
            TableColumn("Name") { s in Text(DisplayText.safe(s.name)) }.width(min: 140, ideal: 180)
            TableColumn("Domains") { s in Text(s.domains.joined(separator: ", ")).lineLimit(2) }.width(min: 120, ideal: 170)
            TableColumn("Belege") { s in Text(s.evidence).foregroundStyle(.secondary).lineLimit(2).help(s.evidence) }.width(min: 160, ideal: 230)
            TableColumn("Zeitraum") { s in
                Text([s.first, s.last].compactMap { $0.map { $0.formatted(.dateTime.year()) } }.joined(separator: "–")).monospacedDigit()
            }
            .width(80)
            TableColumn("") { s in
                HStack(spacing: 4) {
                    Button("Bestätigen") { draft = RelationDraft(s) }.controlSize(.small)
                    Button("Ablehnen") { Task { message = await model.rejectRelation(s) } }.controlSize(.small)
                }
            }
            .width(170)
        }
    }

    private var rejectedTable: some View {
        Table(rejected) {
            TableColumn("Name") { r in Text(DisplayText.safe(r.name)).foregroundStyle(.secondary) }
            TableColumn("Domains") { r in Text(r.domains.joined(separator: ", ")).foregroundStyle(.secondary) }
            TableColumn("") { r in Button("Doch bestätigen …") { draft = RelationDraft(r) }.controlSize(.small) }.width(140)
        }
    }
}

struct RelationDraft: Identifiable {
    var id = UUID().uuidString
    var existing: String?
    var name = ""
    var domains = ""
    var hasSince = false
    var since = Date.now
    var ended = false
    var until = Date.now

    init() {}

    init(_ r: Relation) {
        existing = r.id
        name = r.name
        domains = r.domains.joined(separator: ", ")
        if let s = r.since { hasSince = true; since = s }
        if let u = r.until { ended = true; until = u }
    }

    init(_ s: RelationSuggestion) {
        name = s.name
        domains = s.domains.joined(separator: ", ")
        if let first = s.first { hasSince = true; since = first }
    }
}

private struct RelationEditor: View {
    let model: AppModel
    @State var draft: RelationDraft
    let done: (String?) -> Void
    @State private var saving = false

    var body: some View {
        Form {
            TextField("Name", text: $draft.name, prompt: Text("z. B. Sparkasse KölnBonn"))
            TextField("Domains", text: $draft.domains, prompt: Text("sparkasse-koelnbonn.de, s-koelnbonn.de"))
            Text("Nur Domains, von denen sie dir wirklich schreiben – eine Mail, die den Namen nennt und von einer anderen kommt, wird verdächtig.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Beziehung seit", isOn: $draft.hasSince)
            if draft.hasSince { DatePicker("", selection: $draft.since, displayedComponents: .date).labelsHidden() }
            Toggle("Beziehung beendet", isOn: $draft.ended)
            if draft.ended {
                DatePicker("", selection: $draft.until, displayedComponents: .date).labelsHidden()
                Text("Beendet heißt nicht Spam: Schlussrechnungen und Steuerbelege kommen noch. MailKeeper vertraut nur weniger.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    saving = true
                    Task {
                        let domains = draft.domains.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
                        let problem = await model.saveRelation(id: draft.existing, name: draft.name, domains: domains,
                                                               since: draft.hasSince ? draft.since : nil, until: draft.ended ? draft.until : nil)
                        saving = false
                        done(problem)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.domains.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}

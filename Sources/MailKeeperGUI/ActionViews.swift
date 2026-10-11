import MailKeeperKit
import SwiftUI

/// The plan before anything happens (ADR-0006): what would run, what is skipped and why,
/// examples — then the user's go.
struct PlanSheet: View {
    let model: AppModel
    let plan: PlannedAction
    @State private var graceDays: Int
    @State private var destination: RestoreOptions.Destination
    @State private var keepDate: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, plan: PlannedAction) {
        self.model = model
        self.plan = plan
        _graceDays = State(initialValue: plan.job.graceDays ?? 30)
        let restore = plan.job.restore ?? RestoreOptions()
        _destination = State(initialValue: restore.destination)
        _keepDate = State(initialValue: restore.keepDate)
    }

    /// Options can change only while planning from a selection (not on resume or retry).
    private var replannable: Bool { !plan.stored && plan.filter.ids != [] }

    private var job: ActionJob { plan.job }
    private var runs: Int { job.open.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppModel.actionTitle(job.kind)).font(.title3.weight(.semibold))
                Text(DisplayText.safe(job.title)).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text(job.kind == .serverDelete ? "In den Papierkorb des Servers"
                         : job.kind == .restore ? "Auf den Server zurück" : "In den Papierkorb des Archivs")
                    Text("\(runs.formatted()) Mails · \(job.openBytes.formatted(.byteCount(style: .file)))").fontWeight(.semibold)
                }
                if job.kind == .serverDelete {
                    ForEach(plan.summary.perAccount.sorted { $0.key < $1.key }, id: \.key) { account, count in
                        GridRow {
                            Text("Konto \(account)").foregroundStyle(.secondary)
                            Text(count.formatted())
                        }
                    }
                    if plan.summary.archiveOnly > 0 {
                        GridRow {
                            Text("Nur im Archiv (nichts zu tun)").foregroundStyle(.secondary)
                            Text(plan.summary.archiveOnly.formatted())
                        }
                    }
                } else if job.kind == .restore {
                    ForEach(plan.summary.perAccount.sorted { $0.key < $1.key }, id: \.key) { target, count in
                        GridRow {
                            Text("Nach \(DisplayText.safe(target))").foregroundStyle(.secondary).lineLimit(1)
                            Text(count.formatted())
                        }
                    }
                } else if plan.summary.messages - plan.summary.archiveOnly > 0 {
                    GridRow {
                        Text("Davon noch auf einem Server").foregroundStyle(.secondary)
                        Text((plan.summary.messages - plan.summary.archiveOnly).formatted())
                    }
                }
                ForEach(job.reasons, id: \.reason) { reason, count in
                    GridRow {
                        Text("Übersprungen: \(reason)").foregroundStyle(.orange)
                        Text(count.formatted())
                    }
                }
            }
            .font(.callout)

            if job.kind == .serverDelete, !plan.stored {
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $graceDays, in: 0...3650) {
                        Text(graceDays == 1 ? "Schonfrist: 1 Tag ab Eingang auf dem Server"
                                            : "Schonfrist: \(graceDays) Tage ab Eingang auf dem Server")
                    }
                    .onChange(of: graceDays) { model.replan(plan, graceDays: graceDays) }
                    .help("Schützt neue Mails und andere Programme, die das Postfach lesen (z. B. Paperless).")
                    if job.reasons.contains(where: { $0.reason == ArchiveReader.graceReason(job.graceDays ?? graceDays) }) {
                        Text("Gezählt wird ab dem Eingang auf dem Server, nicht ab dem Datum der Mail. Eine alte Mail, die erst kürzlich hochgeladen wurde (Umzug, Import), ist dort neu.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if job.kind == .restore, replannable {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Wohin", selection: $destination) {
                        Text("Wo sie zuletzt lagen").tag(RestoreOptions.Destination.original)
                        ForEach(model.restoreTargets, id: \.account) { target in
                            Section(DisplayText.safe(target.account)) {
                                ForEach(target.mailboxes, id: \.self) { box in
                                    Text(verbatim: DisplayText.safe(box))
                                        .tag(RestoreOptions.Destination.mailbox(account: target.account, mailbox: box))
                                }
                            }
                        }
                    }
                    .fixedSize()
                    Toggle("Ursprüngliches Eingangsdatum behalten", isOn: $keepDate)
                        .help("Aus: Die Mail gilt auf dem Server als heute eingegangen. Proton nimmt immer das Datum aus der Mail.")
                }
                .onChange(of: destination) { model.replan(plan, restore: RestoreOptions(destination: destination, keepDate: keepDate)) }
                .onChange(of: keepDate) { model.replan(plan, restore: RestoreOptions(destination: destination, keepDate: keepDate)) }
            }

            if !plan.examples.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Beispiele").font(.caption).foregroundStyle(.secondary)
                    ForEach(plan.examples) { m in
                        HStack(spacing: 8) {
                            Text(m.date.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            Text(DisplayText.safe(m.fromDisplay)).lineLimit(1).frame(width: 140, alignment: .leading)
                            Text(DisplayText.safe(m.subject ?? "")).lineLimit(1)
                        }
                        .font(.callout)
                    }
                }
            }

            HStack {
                if plan.stored {
                    Button("Verwerfen") { model.discard(job); dismiss() }
                        .help("Den unterbrochenen Auftrag nicht fortsetzen")
                }
                if job.kind == .archiveDelete, !plan.stored, plan.filter.ids != [],
                   job.reasons.contains(where: { $0.reason == ArchiveReader.stillOnServer }) {
                    Button("Zuerst auf dem Server löschen …") {
                        model.plan(.serverDelete, filter: plan.filter, title: job.title)
                    }
                    .help("Im Papierkorb liegt nur, was auf keinem Server mehr ist")
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(runs == 0 ? "Nichts zu tun" : job.kind == .restore ? "Zurückspielen" : "Ausführen",
                       role: job.kind == .restore ? nil : .destructive) { model.execute(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(runs == 0 || model.actionRunning || model.syncRunning || model.importRunning)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var explanation: String {
        switch job.kind {
        case .serverDelete:
            String(localized: "Die Mails wandern in den Papierkorb ihres Servers; das Archiv behält sie. Unmittelbar vorher prüft MailKeeper jede einzelne: Archivkopie intakt, noch dieselbe Mail, nicht inzwischen markiert.")
        case .archiveDelete:
            String(localized: "Die Mails wandern in den Papierkorb des Archivs und werden nach 30 Tagen endgültig gelöscht; bis dahin lassen sie sich wiederherstellen. Was noch auf einem Server liegt, bleibt dort — nach dem endgültigen Löschen holt MailKeeper es nicht wieder.")
        case .restore:
            String(localized: "MailKeeper lädt die Mails aus dem Archiv wieder auf den Server – mit ihrem Status (gelesen, beantwortet, markiert), bei Gmail mit den Labels. Vorher sucht es jede im Zielordner: Was dort schon liegt, kommt nicht doppelt. Danach holt es sie zur Kontrolle zurück. Ordner legt MailKeeper nicht an.")
                + (protonInvolved ? " " + String(localized: "Proton braucht etwa 1,5 Sekunden je Mail und nimmt das Datum aus der Mail.") : "")
        case .export:
            ""
        }
    }

    private var protonInvolved: Bool {
        job.open.contains { $0.target.map { model.accountKind($0.account) == .protonBridge } ?? false }
    }
}

/// After a job: what got done, what failed and why; failed items can go again.
struct ResultSheet: View {
    let model: AppModel
    let job: ActionJob
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(AppModel.actionTitle(job.kind)): fertig").font(.title3.weight(.semibold))
            Text(DisplayText.safe(job.title)).foregroundStyle(.secondary).lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Erledigt"); Text(job.count(.done).formatted()).fontWeight(.semibold) }
                if job.count(.failed) > 0 { GridRow { Text("Fehlgeschlagen").foregroundStyle(.red); Text(job.count(.failed).formatted()) } }
                if job.count(.skipped) > 0 { GridRow { Text("Übersprungen").foregroundStyle(.orange); Text(job.count(.skipped).formatted()) } }
                if !job.open.isEmpty { GridRow { Text("Offen").foregroundStyle(.secondary); Text(job.open.count.formatted()) } }
            }
            .font(.callout)
            if !job.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gründe").font(.caption).foregroundStyle(.secondary)
                    ForEach(job.reasons, id: \.reason) { reason, count in
                        Text("\(count.formatted()) × \(reason)").font(.callout)
                    }
                }
            }
            Text("Jede Aktion steht im Prüfprotokoll (~/Library/Logs/MailKeeper/audit.jsonl).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if job.count(.failed) > 0 {
                    Button("Fehlgeschlagene erneut versuchen …") { model.retryFailed(job) }
                }
                Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Reader pane while several messages are selected.
struct SelectionSummaryView: View {
    let model: AppModel

    var body: some View {
        let ids = model.actionSelection
        let bytes = model.summaries(ids).reduce(Int64(0)) { $0 + Int64($1.size) }
        VStack(spacing: 12) {
            Image(systemName: "envelope.stack").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("\(ids.count.formatted()) Mails ausgewählt").font(.title3.weight(.semibold))
            Text(bytes.formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
            HStack {
                if model.sidebarSelection == .trash {
                    Button("Wiederherstellen") { model.restoreSelection() }
                    Button("Endgültig löschen …", role: .destructive) { Task { await model.purgeSelection() } }
                } else {
                    Button("Auf dem Server löschen …") { model.planSelection(.serverDelete) }
                    Button("Aus dem Archiv löschen …") { model.planSelection(.archiveDelete) }
                    Button("Auf den Server zurückspielen …") { model.planSelection(.restore) }
                }
            }
            .disabled(model.actionRunning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Above the list in the trash view.
struct TrashBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text("Mails im Papierkorb werden nach 30 Tagen endgültig gelöscht.").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Wiederherstellen") { model.restoreSelection() }
                .disabled(model.actionSelection.isEmpty || model.actionRunning)
            Button("Endgültig löschen …") { Task { await model.purgeSelection() } }
                .disabled(model.actionSelection.isEmpty || model.actionRunning)
            Button("Papierkorb leeren …") { Task { await model.emptyTrash() } }
                .disabled((model.stats?.trashed ?? 0) == 0 || model.actionRunning)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

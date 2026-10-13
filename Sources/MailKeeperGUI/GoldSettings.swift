import MailKeeperAI
import MailKeeperKit
import SwiftUI

/// Where a gold run stands.
struct GoldProgress: Equatable {
    var mode: String
    var done: Int
    var total: Int
}

/// One measured mode, with what changed since the last run of it.
struct GoldResult: Identifiable {
    var id: String { report.mode }
    var report: GoldReport
    var worse: [String]
    var flips: [String]
    /// identity → "Sender: subject" for the misses.
    var titles: [String: String]
}

/// One mail in the label sheet.
struct GoldMail {
    var id: Int64
    var identity: String
    var from: String
    var replyTo: String?
    var subject: String
    var date: Date?
    var place: String
    var text: String
    var attachments: [String]
    var findings: [String]
}

extension AppModel {
    /// Mails to label (6.6b): spread over senders and buckets, not what was labelled or skipped.
    func goldCandidates(limit: Int = 120) -> [Int64] {
        (try? reader?.goldCandidates(limit: limit, excluding: goldLabels.seen)) ?? []
    }

    func goldMail(_ id: Int64) -> GoldMail? {
        guard let reader, let detail = try? reader.detail(id), let parsed = try? reader.parsedMessage(id),
              let identity = try? reader.identities(of: [id]).first else { return nil }
        let from = parsed.from.first.map { a in a.name.map { "\($0) <\(a.address)>" } ?? a.address } ?? "—"
        let reply = parsed.replyTo.first?.address
        let links = LinkExtractor.links(html: parsed.html, text: parsed.text).map { LinkCheck(href: $0.href, text: $0.text) }
        return GoldMail(id: id, identity: identity, from: from, replyTo: reply == parsed.from.first?.address ? nil : reply,
                        subject: parsed.subject ?? "", date: parsed.date,
                        place: detail.locations.map { "\($0.account) › \($0.mailbox)" }.joined(separator: ", "),
                        text: String(parsed.text.prefix(2_500)),
                        attachments: parsed.attachments.filter { !$0.isInline }.compactMap(\.filename),
                        findings: links.filter(\.isSuspicious).prefix(4).map { l in
                            "\(l.shownDomain.map { "Text \($0), " } ?? "")Ziel \(l.host ?? l.target): \(l.findings.map(\.text).joined(separator: "; "))"
                        })
    }

    func saveGoldLabel(_ label: GoldLabel) {
        goldLabels.set(label)
        persistGold()
    }

    func skipGold(_ identity: String) {
        goldLabels.skip(identity)
        persistGold()
    }

    func removeGold(_ identity: String) {
        goldLabels.remove(identity)
        persistGold()
    }

    private func persistGold() {
        guard let layout = reader?.layout else { return }
        do { try GoldStore(layout: layout).save(goldLabels) } catch { goldMessage = "\(error)" }
    }

    /// Measures the labelled mails: what MailKeeper shows today, then — with a model — without
    /// and with memory. Reads only; the runs are kept in `gold-runs.jsonl` and compared with
    /// the last run of the same mode and model.
    func runGold() {
        guard goldTask == nil, let root = archiveRoot, !goldLabels.labels.isEmpty else { return }
        let labels = goldLabels
        let router = aiRouter()
        let model = aiConfig.endpoint != nil ? aiConfig.model(for: .classify) : "apple-on-device"
        let embedModel = aiConfig.endpoint != nil ? aiConfig.model(for: .embed) : nil
        goldMessage = nil
        goldResults = []
        goldProgress = GoldProgress(mode: GoldArchive.today, done: 0, total: labels.labels.count)
        goldTask = Task.detached(priority: .utility) { [weak self] in
            var message: String?
            var results: [GoldResult] = []
            do {
                let layout = try ArchiveLayout.open(at: root, create: false)
                let reader = try ArchiveReader(layout: layout)
                var reports = [try GoldArchive.todayReport(reader: reader, labels: labels)]
                if let router {
                    let runner = GoldRunner(classifier: MailClassifier(router: router))
                    let modes: [(String, MemoryRetriever?)] = [(GoldArchive.withoutMemory, nil),
                                                               (GoldArchive.withMemory, try MemoryRetriever(reader: reader, embedModel: embedModel))]
                    for (mode, memory) in modes {
                        try Task.checkCancellation()
                        let items = try GoldArchive.items(reader: reader, labels: labels, memory: memory)
                        await MainActor.run { self?.goldProgress = GoldProgress(mode: mode, done: 0, total: items.count) }
                        let report = await runner.run(items, set: GoldArchive.set, mode: mode, model: model) { done, total in
                            Task { @MainActor in if self?.goldProgress?.mode == mode { self?.goldProgress = GoldProgress(mode: mode, done: done, total: total) } }
                        }
                        try Task.checkCancellation()  // a stopped run is no measurement
                        reports.append(report)
                    }
                } else {
                    message = String(localized: "Ohne KI misst MailKeeper nur, was es heute zeigt (Regeln, ähnliche Mails, deine Entscheidungen).")
                }
                let store = GoldStore(layout: layout)
                let previous = store.runs(as: GoldReport.self)
                let titles = try GoldArchive.titles(reader: reader, identities: labels.labels.map(\.identity))
                for r in reports {
                    let last = previous.last { $0.set == r.set && $0.mode == r.mode && $0.model == r.model }
                    let (worse, flips) = last.map { r.comparison(since: $0) } ?? ([], [])
                    results.append(GoldResult(report: r, worse: worse, flips: flips, titles: titles))
                    try store.appendRun(r)
                }
            } catch is CancellationError {
                message = String(localized: "Angehalten – nichts gespeichert.")
            } catch {
                message = "\(error)"
            }
            await MainActor.run {
                guard let self, self.archiveRoot == root else { return }
                self.goldResults = results
                self.goldMessage = message
                self.goldProgress = nil
                self.goldTask = nil
            }
        }
    }

    func stopGold() { goldTask?.cancel() }
}

/// Settings › Messung (6.6): label mails of the own archive, then measure how well rules and
/// models sort them — with and without memory.
struct GoldSettings: View {
    let model: AppModel
    @State private var labelling = false
    @State private var showLabels = false

    var body: some View {
        Form {
            Section {
                Text("Du ordnest Mails aus deinem Archiv selbst ein; MailKeeper misst daran, wie gut Regeln und KI sie einordnen – mit und ohne Gedächtnis. Die Labels bleiben in deinem Archivordner (gold.json), ändern nichts an deinen Mails und fließen nicht ins Gedächtnis.")
                    .font(.callout).foregroundStyle(.secondary).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("\(model.goldLabels.labels.count) gelabelt · \(model.goldLabels.skipped.count) übersprungen")
                    Spacer()
                    Button("Labels ansehen …") { showLabels = true }.disabled(model.goldLabels.labels.isEmpty)
                    Button("Mails labeln …") { labelling = true }.keyboardShortcut("l", modifiers: [.command])
                }
                Text("Für eine belastbare Zahl: etwa 80 Mails – je Absender eine, über alle Arten und den Spam-Ordner verteilt. MailKeepers eigene Einordnung bleibt beim Labeln verborgen.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Dein Gold-Set") }
            Section {
                HStack {
                    if let p = model.goldProgress {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(maxWidth: 200)
                        Text("\(p.mode): \(p.done)/\(p.total)").monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button("Anhalten") { model.stopGold() }
                    } else {
                        Text(model.aiRouter() == nil ? "Ohne KI: nur „MailKeeper heute“" : "MailKeeper heute, KI ohne und mit Gedächtnis – je Mail eine Anfrage")
                            .foregroundStyle(.secondary).font(.callout)
                        Spacer()
                        Button("Messen") { model.runGold() }.disabled(model.goldLabels.labels.count < 10)
                            .help(model.goldLabels.labels.count < 10 ? "Erst mindestens 10 Mails labeln" : "Läuft im Hintergrund; nur lesend")
                    }
                }
                if let message = model.goldMessage { Text(DisplayText.safe(message)).font(.callout).foregroundStyle(.secondary) }
                ForEach(model.goldResults) { r in GoldResultView(result: r) }
            } header: { Text("Messung") }
        }
        .formStyle(.grouped)
        .frame(minWidth: 720, minHeight: 460)
        .sheet(isPresented: $labelling) { GoldLabelSheet(model: model) }
        .sheet(isPresented: $showLabels) { GoldLabelList(model: model) }
    }
}

private struct GoldResultView: View {
    let result: GoldResult
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(result.report.summary.dropFirst().enumerated()), id: \.offset) { _, line in
                    Text(line.trimmingCharacters(in: .whitespaces)).font(.caption.monospacedDigit())
                }
                if !result.flips.isEmpty {
                    Text("Seit der letzten Messung").font(.caption.weight(.semibold)).padding(.top, 4)
                    ForEach(result.flips, id: \.self) { Text(DisplayText.safe(named($0))).font(.caption) }
                }
                let misses = result.report.outcomes.filter { !$0.right }
                if !misses.isEmpty {
                    Text("Daneben (\(misses.count))").font(.caption.weight(.semibold)).padding(.top, 4)
                    ForEach(misses, id: \.id) { o in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(DisplayText.safe(result.titles[o.id] ?? o.id)).font(.caption).lineLimit(1)
                            Text(DisplayText.safe(miss(o))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayText.safe(result.report.summary.first ?? "")).font(.callout)
                ForEach(result.worse, id: \.self) { Label(DisplayText.safe($0), systemImage: "arrow.down.right").foregroundStyle(.red).font(.caption) }
            }
        }
    }

    private func miss(_ o: GoldOutcome) -> String {
        if let error = o.error { return String(localized: "keine Antwort – \(error)") }
        let want = o.expected.map(\.label).joined(separator: " oder ") + (o.expectedPhishing == .flagged ? String(localized: ", Phishing") : "")
        let got = (o.category?.label ?? "–") + ((o.phishing ?? PhishingLevel.none) == .none ? "" : " (\(o.phishing!.label))")
        return String(localized: "\(got) statt \(want)") + (o.reason.map { " – „\($0)“" } ?? "")
    }

    /// "jetzt falsch: <identity> (…)" with the mail's title instead of its identity.
    private func named(_ line: String) -> String {
        var out = line
        for (identity, title) in result.titles where line.contains(identity) { out = out.replacingOccurrences(of: identity, with: title) }
        return out
    }
}

/// One mail at a time: the category (1–9), phishing (P), skip (0), back (←). What MailKeeper
/// thinks stays hidden — it would only anchor the label.
struct GoldLabelSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [Int64] = []
    @State private var position = 0
    @State private var mail: GoldMail?
    @State private var phishing = false
    @State private var session = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mails labeln").font(.headline)
                Spacer()
                Text("\(session) in dieser Runde · \(model.goldLabels.labels.count) insgesamt").foregroundStyle(.secondary).monospacedDigit()
            }
            if let mail {
                VStack(alignment: .leading, spacing: 3) {
                    row("Von", mail.from)
                    if let reply = mail.replyTo { row("Antwort an", reply) }
                    row("Betreff", mail.subject)
                    row("Datum", mail.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    row("Ablage", mail.place)
                    if !mail.attachments.isEmpty { row("Anhänge", mail.attachments.prefix(5).joined(separator: ", ")) }
                    ForEach(mail.findings, id: \.self) { f in
                        Label(DisplayText.safe(f), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                ScrollView {
                    Text(DisplayText.safe(mail.text)).font(.callout).textSelection(.enabled)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180, maxHeight: 260)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
                Button { phishing.toggle() } label: {
                    Label("Phishing – will Zugangsdaten, Geld oder Daten erschleichen (P)", systemImage: phishing ? "checkmark.square.fill" : "square")
                        .foregroundStyle(phishing ? .red : .primary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: [])
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(Array(MailCategory.allCases.enumerated()), id: \.element) { n, c in
                        Button { label(mail, c) } label: {
                            Label("\(n + 1)  \(c.label)", systemImage: c.icon).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(n + 1)")), modifiers: [])
                    }
                }
                HStack {
                    Button("Zurück") { back() }.keyboardShortcut(.leftArrow, modifiers: []).disabled(position == 0)
                    Button("Weiß nicht (0)") { model.skipGold(mail.identity); next() }.keyboardShortcut("0", modifiers: [])
                    Spacer()
                    Text("MailKeepers Einordnung bleibt verborgen, damit sie dich nicht beeinflusst.").font(.caption).foregroundStyle(.secondary)
                    Button("Fertig") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                ContentUnavailableView("Nichts mehr zu labeln", systemImage: "checkmark.circle",
                                       description: Text("Alle angebotenen Mails sind gelabelt oder übersprungen."))
                HStack { Spacer(); Button("Fertig") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(20)
        .frame(width: 760)
        .onAppear {
            queue = model.goldCandidates()
            show(0)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(DisplayText.safe(value)).lineLimit(2).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func show(_ n: Int) {
        position = n
        mail = n < queue.count ? model.goldMail(queue[n]) : nil
        // an earlier label comes back when going back
        phishing = mail.flatMap { model.goldLabels.label(of: $0.identity)?.phishing } ?? false
    }

    private func label(_ mail: GoldMail, _ category: MailCategory) {
        if model.goldLabels.label(of: mail.identity) == nil { session += 1 }
        model.saveGoldLabel(GoldLabel(identity: mail.identity, category: category, phishing: phishing))
        next()
    }

    private func next() { show(position + 1) }

    private func back() { if position > 0 { show(position - 1) } }
}

/// The labels given, newest first — change by labelling again, or remove.
struct GoldLabelList: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let titles = (try? model.reader.map { try GoldArchive.titles(reader: $0, identities: model.goldLabels.labels.map(\.identity)) }) ?? [:]
        VStack(alignment: .leading, spacing: 10) {
            Text("Deine Labels").font(.headline)
            List {
                ForEach(model.goldLabels.labels.reversed(), id: \.identity) { l in
                    HStack {
                        Label(l.category.label, systemImage: l.category.icon).frame(width: 170, alignment: .leading)
                        if l.phishing { Text("Phishing").foregroundStyle(.red).font(.caption) }
                        Text(DisplayText.safe(titles[l.identity] ?? String(localized: "(nicht mehr im Archiv)"))).lineLimit(1)
                        Spacer()
                        Button("Entfernen") { model.removeGold(l.identity) }.controlSize(.small)
                    }
                }
            }
            .frame(minHeight: 320)
            HStack { Spacer(); Button("Fertig") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 720)
    }
}

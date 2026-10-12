import MailKeeperKit
import SwiftUI

/// "Einschätzung korrigieren" (6.4b, TJ): the mail is genuine. The user's word (journalled),
/// a relation as the firm rule (sender and Reply-To domains belong together), a note for the
/// model, and a new look at this mail and the alike ones.
struct VerdictCorrectionSheet: View {
    let model: AppModel
    let messageID: Int64
    let message: ParsedMessage
    let classification: Classification?
    let done: () -> Void

    @State private var saveRelation = true
    @State private var relationName = ""
    /// The relation's domains as the user leaves them: an existing relation's, this mail's, and
    /// the options it ticked (pre-ticked only with evidence — review 6 S2).
    @State private var fixedDomains: [String] = []
    @State private var options: [ProposedRelation.Domain] = []
    @State private var chosen: Set<String> = []
    @State private var saveNote = true
    @State private var note = ""
    @State private var recheck = true
    @State private var alike: [Int64] = []
    @State private var saving = false
    @State private var problem: String?

    private var senderDomain: String? { Self.domain(message.from.first?.address) }
    private var replyDomain: String? { Self.domain(message.replyTo.first?.address) }
    private var existing: Relation? {
        guard let d = senderDomain else { return nil }
        return model.relations.first { $0.confirmed && $0.domains.contains(d) }
    }

    static func domain(_ address: String?) -> String? {
        guard let a = address?.lowercased(), let at = a.lastIndex(of: "@") else { return nil }
        let host = String(a[a.index(after: at)...])
        return host.isEmpty ? nil : LinkCheck.registrableDomain(host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Einschätzung korrigieren").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Die KI meint:").foregroundStyle(.secondary)
                if let level = classification?.phishing, level != .none {
                    Text("\(level.label): \(DisplayText.safe(classification?.phishingReason ?? "—"))")
                }
                if classification?.category == .spam { Text("Spam: \(DisplayText.safe(classification?.reason ?? "—"))") }
            }
            .font(.callout)

            Label("Diese Mail ist echt – kein Phishing, kein Spam", systemImage: "checkmark.seal")
                .fontWeight(.medium)
            Text("Dein Urteil gilt für diese Mail und überdauert jede neue Einschätzung.").font(.caption).foregroundStyle(.secondary)

            Divider()
            Toggle(isOn: $saveRelation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing.map { "Beziehung „\(DisplayText.safe($0.name))“ ergänzen" } ?? "Als Beziehung eintragen (feste Regel)")
                    Text("Absender- und Antwortadresse dieser Domains gehören zusammen; Nachahmer anderer Domains fallen auf.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if saveRelation {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Name").foregroundStyle(.secondary)
                        TextField("z. B. PayPal", text: $relationName).disabled(existing != nil)
                    }
                    Text("Domains: \(fixedDomains.joined(separator: ", "))").font(.callout)
                    if !options.isEmpty {
                        Text("Auch dazu? Nur ankreuzen, wenn du sicher bist – vorgewählt ist, wofür es Belege gibt.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(options, id: \.domain) { option in
                            Toggle(isOn: Binding(get: { chosen.contains(option.domain) },
                                                 set: { on in if on { chosen.insert(option.domain) } else { chosen.remove(option.domain) } })) {
                                Text("\(option.domain) – \(option.mails) Mails · \(option.why)")
                                    .foregroundStyle(option.why.hasPrefix("Warnung") ? .red : .primary)
                            }
                        }
                    }
                }
                .padding(.leading, 20)
            }
            Toggle(isOn: $saveNote) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hinweis für die KI merken")
                    Text("Wird zur Notiz für \(senderDomain ?? "die Domain") – die KI bekommt sie bei jeder Mail von dort.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if saveNote {
                TextField("Hinweis", text: $note, axis: .vertical).lineLimit(2...4).padding(.leading, 20)
            }
            Toggle(isOn: $recheck) {
                Text(alike.isEmpty ? "Diese Mail neu einordnen" : "Diese und \(alike.count) gleichartige Mails neu einordnen")
            }
            .disabled(!model.aiConfig.enabled)
            if let problem { Text(DisplayText.safe(problem)).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Abbrechen", action: done).keyboardShortcut(.cancelAction)
                Button("Übernehmen") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (saveRelation && (relationName.trimmingCharacters(in: .whitespaces).isEmpty || domainList.isEmpty)))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: prefill)
    }

    private var domainList: [String] {
        fixedDomains + options.map(\.domain).filter(chosen.contains)
    }

    private func prefill() {
        // the sender's domain, and as options the sister domains and the Reply-To (review 6 S2)
        let proposal = model.proposedRelation(for: messageID, replyTo: message.replyTo.first?.address)
        let own = proposal.domains.first.map { [$0.domain] } ?? [senderDomain].compactMap { $0 }
        let base = Array(NSOrderedSet(array: (existing?.domains ?? []) + own)).compactMap { $0 as? String }
        fixedDomains = base
        options = proposal.domains.dropFirst().filter { !base.contains($0.domain) }
        chosen = Set(options.filter(\.evidence).map(\.domain))
        if let existing {
            relationName = existing.name
            saveRelation = !Set(own).isSubset(of: Set(existing.domains)) || !options.isEmpty
        } else {
            relationName = proposal.name.isEmpty ? (senderDomain ?? "") : DisplayText.safe(proposal.name)
        }
        if let s = senderDomain {
            note = "Mails von \(s) sind echt."
        } else {
            saveNote = false
        }
        let all = Set(base + options.map(\.domain))
        alike = model.modelFlagged(fromDomains: all, name: message.from.first?.name, excluding: messageID)
    }

    private func apply() {
        saving = true
        Task {
            let relation = saveRelation ? (id: existing?.id, name: relationName, domains: domainList) : nil
            problem = await model.correctVerdict(messageID: messageID, note: saveNote ? note : nil, noteDomain: senderDomain ?? "",
                                                 relation: relation, recheck: recheck ? alike + [messageID] : [])
            saving = false
            if problem == nil { done() }
        }
    }
}

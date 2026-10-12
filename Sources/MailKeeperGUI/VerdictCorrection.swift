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
    @State private var relationDomains = ""
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
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Name").foregroundStyle(.secondary)
                        TextField("z. B. PayPal", text: $relationName).disabled(existing != nil)
                    }
                    GridRow {
                        Text("Domains").foregroundStyle(.secondary)
                        TextField("paypal.de, paypal.com", text: $relationDomains)
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
                    .disabled(saving || (saveRelation && (relationName.trimmingCharacters(in: .whitespaces).isEmpty || relationDomains.isEmpty)))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: prefill)
    }

    private var domainList: [String] {
        relationDomains.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
    }

    private func prefill() {
        // the sender's domain, the sister domains its name used with a passing check, the Reply-To
        let proposal = model.proposedRelation(for: messageID, replyTo: message.replyTo.first?.address)
        let domains = proposal.domains.isEmpty ? [senderDomain].compactMap { $0 } : proposal.domains
        if let existing {
            relationName = existing.name
            relationDomains = Array(NSOrderedSet(array: existing.domains + domains)).compactMap { $0 as? String }.joined(separator: ", ")
            saveRelation = !Set(domains).isSubset(of: Set(existing.domains))  // nothing to add: off
        } else {
            relationName = proposal.name.isEmpty ? (senderDomain ?? "") : DisplayText.safe(proposal.name)
            relationDomains = domains.joined(separator: ", ")
        }
        if let s = senderDomain {
            let others = domains.filter { $0 != s }
            note = others.isEmpty ? "Mails von \(s) sind echt."
                : "Mails von \(s) und \(others.joined(separator: ", ")) gehören zusammen und sind echt."
        } else {
            saveNote = false
        }
        let all = Set(domains + (existing?.domains ?? []))
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

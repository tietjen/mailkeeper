import MailKeeperAI
import MailKeeperKit
import SwiftUI

/// Settings › KI: endpoint, key, models per task, the on-device fallback, connection test.
struct AISettings: View {
    let model: AppModel
    @State private var enabled = false
    @State private var endpoint = ""
    @State private var key = ""
    @State private var models: [AITask: String] = [:]
    @State private var onDevice = true
    @State private var report: AIRouter.TestReport?
    @State private var testing = false
    @State private var message: String?

    private static let tasks: [(AITask, LocalizedStringKey)] = [
        (.search, "Suche in Alltagssprache"), (.classify, "Einordnen"), (.summarize, "Zusammenfassen"), (.embed, "Embeddings"),
    ]

    var body: some View {
        Form {
            Toggle("KI-Funktionen verwenden", isOn: $enabled)
            Section("Endpoint (OpenAI-kompatibel, z. B. LiteLLM, Ollama, LM Studio)") {
                // TJ took the grey example for a value: the prompt says it is one, and how it looks
                TextField("Adresse", text: $endpoint, prompt: Text("leer – z. B. http://localhost:11434/v1"))
                SecureField("API-Schlüssel", text: $key, prompt: Text(model.aiKeyStored ? "gespeichert – leer lassen, um ihn zu behalten" : "optional"))
                if parsedEndpoint == nil, !key.isEmpty {
                    Label("Erst die Adresse eintragen – der Schlüssel gehört zu ihr.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                if let url = parsedEndpoint {
                    if let problem = AIConfig.transportProblem(url) {
                        Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
                    } else if !AIConfig.isLocal(url) {
                        Label("Diese Adresse liegt nicht im lokalen Netz: Mailinhalte würden dein Netz verlassen.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
            }
            Section("Modell je Aufgabe") {
                ForEach(Self.tasks, id: \.0) { task, title in
                    TextField(title, text: Binding(get: { models[task] ?? "" }, set: { models[task] = $0 }),
                              prompt: Text("Standard: \(AIConfig().model(for: task))"))
                }
                if let available = report?.models, !available.isEmpty {
                    Text("Freigegeben: \(available.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Modell auf diesem Mac verwenden, wenn der Endpoint fehlt oder nicht antwortet", isOn: $onDevice)
                Text("Apple Intelligence: \(OnDeviceProvider.availability.reason). Schneller, aber ungenauer; was es erzeugt, ist gekennzeichnet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let report {
                Section("Verbindungstest") {
                    ForEach(report.lines) { line in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.title)
                                Text(DisplayText.safe(line.detail)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        } icon: {
                            Image(systemName: line.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(line.ok ? .green : .red)
                        }
                    }
                }
            }
            Section {
                HStack {
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if model.aiKeyStored {
                        Button("Schlüssel löschen") { model.removeAIKey() }
                    }
                    Button(testing ? "Teste …" : "Verbindung testen") {
                        testing = true
                        let config = draft, typed = key
                        Task {
                            report = await model.testAI(config, key: typed)
                            testing = false
                        }
                    }
                    .disabled(testing || (parsedEndpoint == nil && !onDevice))
                    Button("Sichern") {
                        do {
                            try model.saveAI(draft, key: key)
                            key = ""
                            message = String(localized: "Gesichert")
                        } catch {
                            message = "\(error)"
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Text("Mails gehen nur an diesen Endpoint und an das Modell auf diesem Mac – an keinen Cloud-Dienst. Jeder Aufruf steht ohne Inhalt im Protokoll (\(DisplayPath.tilde(AICallLog.defaultURL.path))). Die KI schlägt nur vor; löschen oder verschieben tut sie nie.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 620)
        .onAppear(perform: load)
    }

    private var parsedEndpoint: URL? {
        let t = endpoint.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : URL(string: t)
    }

    private var draft: AIConfig {
        var c = model.aiConfig
        c.enabled = enabled
        c.endpoint = parsedEndpoint
        c.onDevice = onDevice
        for (task, _) in Self.tasks { c.setModel(models[task] ?? "", for: task) }
        return c
    }

    private func load() {
        let c = model.aiConfig
        enabled = c.enabled
        endpoint = c.endpoint?.absoluteString ?? ""
        onDevice = c.onDevice
        models = Dictionary(uniqueKeysWithValues: Self.tasks.compactMap { task, _ in c.models[task.rawValue].map { (task, $0) } })
    }
}

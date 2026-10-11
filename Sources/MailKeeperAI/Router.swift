import Foundation
import MailKeeperKit

/// `~/Library/Logs/MailKeeper/ai.jsonl` (0600): every model call with task, path, model,
/// seconds, tokens, finish reason, attempt and outcome (ADR-0004 §5) — never prompt or answer.
public struct AICallLog: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var time: Double
        public var task: AITask
        public var path: AIPath
        public var model: String
        public var seconds: Double
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var finish: String?
        public var attempt: Int
        /// "ok" or the kind of error (no server text: it may echo content).
        public var outcome: String
    }

    public let url: URL

    public init(url: URL = AICallLog.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/MailKeeper/ai.jsonl")
    }

    func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0)) }
    }

    static func outcome(_ error: Error) -> String {
        switch error {
        case let e as AIError:
            switch e {
            case .notConfigured: "not-configured"
            case .unavailable: "unavailable"
            case .connection: "connection"
            case .timeout: "timeout"
            case .server(let code, _): "http-\(code)"
            case .badAnswer: "bad-answer"
            case .truncated: "truncated"
            }
        case is CancellationError: "cancelled"
        default: "error"
        }
    }
}

/// Chooses the path per request (ADR-0004): the configured endpoint first — the quality path —
/// and Apple's on-device model when the endpoint is not set up, unreachable or hanging (if the
/// settings allow it). After the endpoint failed to answer it is skipped for a minute instead of
/// costing every request a timeout. Embeddings come from the endpoint only.
public actor AIRouter {
    public let config: AIConfig
    let endpoint: OpenAICompatibleProvider?
    let onDevice: (any ChatProvider)?
    let log: AICallLog
    private var endpointPausedUntil: ContinuousClock.Instant?

    public init(config: AIConfig, apiKey: String?, log: AICallLog = AICallLog()) {
        self.config = config
        endpoint = config.endpoint.map { OpenAICompatibleProvider(baseURL: $0, apiKey: apiKey, timeout: config.timeout) }
        onDevice = config.onDevice ? OnDeviceProvider(timeout: min(config.timeout, 45)) : nil
        self.log = log
    }

    /// For tests: any providers.
    init(config: AIConfig, endpoint: OpenAICompatibleProvider?, onDevice: (any ChatProvider)?, log: AICallLog) {
        self.config = config
        self.endpoint = endpoint
        self.onDevice = onDevice
        self.log = log
    }

    public var isReady: Bool { config.enabled && (endpoint != nil || (onDevice != nil && OnDeviceProvider.availability.available)) }

    public func chat(_ request: ChatRequest) async throws -> ChatResult {
        guard config.enabled else { throw AIError.notConfigured }
        var failure: Error = AIError.notConfigured
        if let endpoint, !endpointPaused {
            do {
                return try await logged(request.task, .endpoint, config.model(for: request.task)) {
                    try await endpoint.chat(request, model: self.config.model(for: request.task), attempt: 1)
                }
            } catch let error as AIError where error.isUnreachable || error == .timeout(config.timeout) {
                endpointPausedUntil = .now + .seconds(60)
                failure = error
            }
        }
        if let onDevice {
            var small = request
            if let compact = request.compactUser { small.user = compact }
            return try await logged(request.task, .onDevice, "apple-on-device") {
                try await onDevice.chat(small, model: "apple-on-device", attempt: 1)
            }
        }
        throw failure
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard config.enabled, let endpoint else { throw AIError.notConfigured }
        let start = ContinuousClock.now
        let model = config.model(for: .embed)
        do {
            let vectors = try await endpoint.embed(texts, model: model)
            log.append(.init(time: Date().timeIntervalSince1970, task: .embed, path: .endpoint, model: model,
                             seconds: (ContinuousClock.now - start).seconds, attempt: 1, outcome: "ok"))
            return vectors
        } catch {
            log.append(.init(time: Date().timeIntervalSince1970, task: .embed, path: .endpoint, model: model,
                             seconds: (ContinuousClock.now - start).seconds, attempt: 1, outcome: AICallLog.outcome(error)))
            throw error
        }
    }

    private var endpointPaused: Bool {
        guard let until = endpointPausedUntil else { return false }
        if .now >= until { endpointPausedUntil = nil; return false }
        return true
    }

    private func logged(_ task: AITask, _ path: AIPath, _ model: String,
                        _ call: () async throws -> ChatResult) async throws -> ChatResult {
        let start = ContinuousClock.now
        do {
            let result = try await call()
            log.append(.init(time: Date().timeIntervalSince1970, task: task, path: path, model: result.model, seconds: result.seconds,
                             promptTokens: result.promptTokens, completionTokens: result.completionTokens,
                             finish: result.finishReason, attempt: result.attempt, outcome: "ok"))
            return result
        } catch {
            log.append(.init(time: Date().timeIntervalSince1970, task: task, path: path, model: model,
                             seconds: (ContinuousClock.now - start).seconds, attempt: 1, outcome: AICallLog.outcome(error)))
            throw error
        }
    }

    // MARK: Connection test

    public struct TestReport: Sendable {
        public struct Line: Sendable, Identifiable {
            public var id: String { title }
            public var title: String
            public var ok: Bool
            public var detail: String
        }
        public var lines: [Line] = []
        public var models: [String] = []
    }

    /// Endpoint (models the key may use, a tiny structured answer, an embedding) and the
    /// on-device model — each line says what worked and how long it took.
    public func test() async -> TestReport {
        var report = TestReport()
        if let endpoint {
            do {
                report.models = try await endpoint.models()
                report.lines.append(.init(title: String(localized: "Endpoint"), ok: true,
                                          detail: String(localized: "\(report.models.count) Modelle freigegeben: \(report.models.joined(separator: ", "))")))
            } catch {
                report.lines.append(.init(title: String(localized: "Endpoint"), ok: false, detail: "\(error)"))
            }
            let probe = Self.probe
            let model = config.model(for: .search)
            do {
                let r = try await logged(.test, .endpoint, model) { try await endpoint.chat(probe, model: model, attempt: 1) }
                let ok = (try? r.decode(Probe.self))?.answer.lowercased() == "ok"
                report.lines.append(.init(title: String(localized: "Antworten (\(model))"), ok: ok,
                                          detail: String(format: "%.1f s", r.seconds) + (ok ? "" : String(localized: " · unerwartete Antwort"))))
            } catch {
                report.lines.append(.init(title: String(localized: "Antworten (\(model))"), ok: false, detail: "\(error)"))
            }
            let embedModel = config.model(for: .embed)
            do {
                let start = ContinuousClock.now
                let v = try await endpoint.embed(["MailKeeper Verbindungstest"], model: embedModel)
                report.lines.append(.init(title: String(localized: "Embeddings (\(embedModel))"), ok: true,
                                          detail: String(format: "%d Dimensionen · %.1f s", v.first?.count ?? 0, (ContinuousClock.now - start).seconds)))
            } catch {
                report.lines.append(.init(title: String(localized: "Embeddings (\(embedModel))"), ok: false, detail: "\(error)"))
            }
        } else {
            report.lines.append(.init(title: String(localized: "Endpoint"), ok: false,
                                      detail: String(localized: "keine Adresse eingetragen (ein grauer Text im Feld ist nur ein Beispiel)")))
        }
        let availability = OnDeviceProvider.availability
        if let onDevice, availability.available {
            do {
                let r = try await logged(.test, .onDevice, "apple-on-device") { try await onDevice.chat(Self.probe, model: "apple-on-device", attempt: 1) }
                report.lines.append(.init(title: String(localized: "Modell auf diesem Mac"), ok: true, detail: String(format: "%.1f s", r.seconds)))
            } catch {
                report.lines.append(.init(title: String(localized: "Modell auf diesem Mac"), ok: false, detail: "\(error)"))
            }
        } else {
            report.lines.append(.init(title: String(localized: "Modell auf diesem Mac"), ok: false,
                                      detail: config.onDevice ? availability.reason : String(localized: "ausgeschaltet")))
        }
        return report
    }

    struct Probe: Decodable { var answer: String }

    static let probe = ChatRequest(task: .test, system: "Du bist ein Verbindungstest. Antworte im verlangten JSON-Format.",
                                   user: "Antworte mit dem Wort ok.",
                                   schema: .object(name: "probe", properties: [.init("answer", .string())]), maxTokens: 50)
}

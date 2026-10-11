import Foundation
import FoundationModels
import MailKeeperKit
import Synchronization

/// One request to a language model. `system` holds the instructions, `user` the data (mail
/// content goes in there, fenced — see `Fence`).
public struct ChatRequest: Sendable {
    public var task: AITask
    public var system: String
    public var user: String
    public var schema: AISchema?
    public var maxTokens: Int

    public init(task: AITask, system: String, user: String, schema: AISchema? = nil, maxTokens: Int = 800) {
        self.task = task
        self.system = system
        self.user = user
        self.schema = schema
        self.maxTokens = maxTokens
    }
}

/// Which path produced an answer — the UI says it (ADR-0004: quality differs).
public enum AIPath: String, Codable, Sendable {
    /// The configured OpenAI-compatible endpoint (homelab LiteLLM).
    case endpoint
    /// Apple's model on this Mac.
    case onDevice
}

public struct ChatResult: Sendable {
    /// The answer text; for a schema request, its JSON.
    public var text: String
    public var path: AIPath
    public var model: String
    public var seconds: Double
    public var finishReason: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var attempt: Int

    /// The structured answer decoded.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(text.utf8)) } catch {
            throw AIError.badAnswer(String(localized: "Antwort passt nicht zum erwarteten Format"))
        }
    }
}

public enum AIError: Error, CustomStringConvertible, Equatable {
    case notConfigured
    case unavailable(String)
    case connection(String)
    case timeout(Double)
    case server(Int, String)
    case badAnswer(String)
    case truncated

    public var description: String {
        switch self {
        case .notConfigured: String(localized: "Die KI ist nicht eingerichtet (Einstellungen › KI)")
        case .unavailable(let s): String(localized: "Kein Modell verfügbar: \(s)")
        case .connection(let s): String(localized: "Endpoint nicht erreichbar: \(s)")
        case .timeout(let s): String(localized: "Keine Antwort nach \(Int(s)) s")
        case .server(let code, let s): String(localized: "Endpoint meldet \(code): \(s)")
        case .badAnswer(let s): s
        case .truncated: String(localized: "Antwort abgeschnitten (Token-Grenze erreicht)")
        }
    }

    /// Worth trying the other path (on-device) — the endpoint is away, not wrong.
    var isUnreachable: Bool {
        switch self {
        case .connection, .notConfigured: true
        case .server(let code, _): code == 502 || code == 503 || code == 504
        default: false
        }
    }
}

/// A language model behind one of the two paths.
public protocol ChatProvider: Sendable {
    var path: AIPath { get }
    func chat(_ request: ChatRequest, model: String, attempt: Int) async throws -> ChatResult
}

// MARK: - OpenAI-compatible endpoint

/// `/chat/completions` and `/embeddings` of an OpenAI-compatible API (LiteLLM). Lessons from
/// the homelab gateway (wiki): virtual keys (`sk-…`), reasoning arrives as `reasoning_content`
/// or `reasoning`, a too small `max_tokens` leaves `content` empty with `finish_reason: length`,
/// and a timeout is never repeated (the generation keeps running on the server). Connection
/// failures and 502/503/429 get one more try.
public struct OpenAICompatibleProvider: ChatProvider {
    public let path = AIPath.endpoint
    public let baseURL: URL
    let apiKey: String?
    let timeout: Double
    let session: URLSession

    public init(baseURL: URL, apiKey: String?, timeout: Double) {
        self.init(baseURL: baseURL, apiKey: apiKey, timeout: timeout, protocolClasses: nil)
    }

    /// Tests put a URLProtocol stub in front.
    init(baseURL: URL, apiKey: String?, timeout: Double, protocolClasses: [AnyClass]?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral  // no cookies, no cache on disk
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    public func chat(_ request: ChatRequest, model: String, attempt: Int) async throws -> ChatResult {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": request.maxTokens,
            "messages": [["role": "system", "content": request.system], ["role": "user", "content": request.user]],
        ]
        if let schema = request.schema {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": schema.name, "strict": true, "schema": schema.jsonSchema()]]
        }
        let start = ContinuousClock.now
        let json = try await post("chat/completions", body, limit: 4 << 20)
        guard let choice = (json["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            throw AIError.badAnswer(String(localized: "Antwort ohne Inhalt"))
        }
        let finish = choice["finish_reason"] as? String
        guard let content = message["content"] as? String, !content.isEmpty else {
            throw finish == "length" ? AIError.truncated : AIError.badAnswer(String(localized: "Antwort ohne Inhalt"))
        }
        let usage = json["usage"] as? [String: Any]
        return ChatResult(text: Self.stripFences(content), path: .endpoint, model: (json["model"] as? String) ?? model,
                          seconds: (ContinuousClock.now - start).seconds, finishReason: finish,
                          promptTokens: usage?["prompt_tokens"] as? Int, completionTokens: usage?["completion_tokens"] as? Int,
                          attempt: attempt)
    }

    /// Vectors in input order.
    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let json = try await post("embeddings", ["model": model, "input": texts], limit: 64 << 20)
        guard let data = json["data"] as? [[String: Any]], data.count == texts.count else {
            throw AIError.badAnswer(String(localized: "Embedding-Antwort unvollständig"))
        }
        let ordered = data.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return try ordered.map { item in
            guard let vector = item["embedding"] as? [Double], !vector.isEmpty else { throw AIError.badAnswer(String(localized: "Embedding ohne Vektor")) }
            return vector.map(Float.init)
        }
    }

    /// The models the key may use.
    public func models() async throws -> [String] {
        let json = try await request("models", body: nil, limit: 1 << 20)
        return ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    private func post(_ endpoint: String, _ body: [String: Any], limit: Int) async throws -> [String: Any] {
        do {
            return try await request(endpoint, body: body, limit: limit)
        } catch let error as AIError where Self.retryable(error) {
            try await Task.sleep(for: .seconds(1.5))
            return try await request(endpoint, body: body, limit: limit)
        }
    }

    static func retryable(_ error: AIError) -> Bool {
        switch error {
        case .connection: true
        case .server(let code, _): code == 429 || code == 502 || code == 503
        default: false  // a timeout is not repeated: the server is still generating
        }
    }

    private func request(_ endpoint: String, body: [String: Any]?, limit: Int) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appending(path: endpoint))
        req.httpMethod = body == nil ? "GET" : "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            if error.code == .timedOut { throw AIError.timeout(timeout) }
            if error.code == .cancelled { throw CancellationError() }
            throw AIError.connection(error.localizedDescription)
        }
        guard data.count <= limit else { throw AIError.badAnswer(String(localized: "Antwort zu groß")) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw AIError.server(status, Self.errorText(data)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badAnswer(String(localized: "Antwort ist kein JSON"))
        }
        return json
    }

    /// The server's error message, bounded and without control or bidi characters.
    static func errorText(_ data: Data) -> String {
        var text = String(decoding: data.prefix(2_000), as: UTF8.self)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            text = message
        }
        let kept = DisplayText.safe(text).unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return String(String(String.UnicodeScalarView(kept)).prefix(240))
    }

    /// Some models wrap JSON in a Markdown code fence despite `response_format`.
    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Apple on-device

/// Apple's on-device model (never Private Cloud Compute: ADR-0004, local only). A fresh session
/// per request, greedy sampling, and a hard timeout that does not rely on cancellation — spike
/// S3 saw requests hang forever.
public struct OnDeviceProvider: ChatProvider {
    public let path = AIPath.onDevice
    let timeout: Double

    public init(timeout: Double = 30) {
        self.timeout = timeout
    }

    public static var availability: (available: Bool, reason: String) {
        switch SystemLanguageModel.default.availability {
        case .available: return (true, String(localized: "verfügbar"))
        case .unavailable(.deviceNotEligible): return (false, String(localized: "dieser Mac unterstützt Apple Intelligence nicht"))
        case .unavailable(.appleIntelligenceNotEnabled): return (false, String(localized: "Apple Intelligence ist ausgeschaltet"))
        case .unavailable(.modelNotReady): return (false, String(localized: "das Modell wird noch geladen"))
        case .unavailable: return (false, String(localized: "nicht verfügbar"))
        }
    }

    public func chat(_ request: ChatRequest, model: String, attempt: Int) async throws -> ChatResult {
        guard Self.availability.available else { throw AIError.unavailable(Self.availability.reason) }
        let start = ContinuousClock.now
        let system = request.system, user = request.user, schema = request.schema
        let text: String = try await withHardTimeout(timeout) {
            let session = LanguageModelSession(model: SystemLanguageModel(useCase: .general), instructions: system)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maxTokens)
            do {
                if let schema {
                    let generation = try GenerationSchema(root: schema.dynamic(), dependencies: [])
                    return try await session.respond(to: user, schema: generation, options: options).content.jsonString
                }
                return try await session.respond(to: user, options: options).content
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error { throw AIError.badAnswer(String(localized: "Text zu lang für das Modell auf dem Mac")) }
                throw AIError.badAnswer(String(localized: "Modell auf dem Mac: \(error.localizedDescription)"))
            }
        }
        return ChatResult(text: text, path: .onDevice, model: "apple-on-device", seconds: (ContinuousClock.now - start).seconds,
                          finishReason: nil, promptTokens: nil, completionTokens: nil, attempt: attempt)
    }
}

/// Races `op` against a timer without a task group: a group would wait for a child that
/// ignores cancellation (a hung on-device request), so it would never return.
func withHardTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let once = OnceFlag()
        let work = Task {
            do { let v = try await op(); if once.claim() { cont.resume(returning: v) } } catch { if once.claim() { cont.resume(throwing: error) } }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.claim() { work.cancel(); cont.resume(throwing: AIError.timeout(seconds)) }
        }
    }
}

final class OnceFlag: Sendable {
    private let done = Mutex(false)
    func claim() -> Bool { done.withLock { if $0 { return false }; $0 = true; return true } }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

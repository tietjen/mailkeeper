import Foundation
import Synchronization
import Testing
@testable import MailKeeperAI
@testable import MailKeeperKit

/// Answers requests from a script: one response per call, in order; records what was asked.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var body: String; var error: URLError.Code? = nil }
    static let script = Mutex<[Reply]>([])
    static let seen = Mutex<[URLRequest]>([])

    static func load(_ replies: [Reply]) { script.withLock { $0 = replies }; seen.withLock { $0 = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var r = request
        if r.httpBody == nil, let stream = r.httpBodyStream {  // URLSession moves the body into a stream
            stream.open()
            var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
            r.httpBody = data
        }
        Self.seen.withLock { $0.append(r) }
        let reply = Self.script.withLock { $0.isEmpty ? Reply(status: 500, body: "{}") : $0.removeFirst() }
        if let code = reply.error { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Stands in for the on-device model.
struct FakeOnDevice: ChatProvider {
    let path = AIPath.onDevice
    let answer: String
    func chat(_ request: ChatRequest, model: String, attempt: Int) async throws -> ChatResult {
        ChatResult(text: answer, path: .onDevice, model: "apple-on-device", seconds: 0.1, attempt: attempt)
    }
}

func completion(_ content: String?, finish: String = "stop") -> String {
    let c = content.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed), as: UTF8.self) } ?? "null"
    return """
    {"model":"llm-fast","choices":[{"finish_reason":"\(finish)","message":{"role":"assistant","content":\(c),"reasoning_content":"secret thoughts"}}],
     "usage":{"prompt_tokens":12,"completion_tokens":3}}
    """
}

@Suite("KI-Anbindung (ADR-0004)", .serialized)
struct AITests {
    let base = URL(string: "http://llm.example.ziti:4000/v1")!
    var provider: OpenAICompatibleProvider { OpenAICompatibleProvider(baseURL: base, apiKey: "sk-test", timeout: 5, protocolClasses: [StubProtocol.self]) }
    let request = ChatRequest(task: .search, system: "sys", user: "Mailinhalt GEHEIM",
                              schema: .object(name: "q", properties: [.init("query", .string()), .init("why", .string(), optional: true)]))

    @Test func schemaIsStrictJSONSchema() throws {
        let s = request.schema!.jsonSchema()
        #expect(s["additionalProperties"] as? Bool == false)
        #expect(s["required"] as? [String] == ["query", "why"])
        let why = (s["properties"] as? [String: Any])?["why"] as? [String: Any]
        #expect(why?["type"] as? [String] == ["string", "null"])
    }

    @Test func configKnowsLocalEndpointsAndTransport() throws {
        #expect(AIConfig.isLocal(URL(string: "http://llm.example.ziti:4000/v1")!))
        #expect(!AIConfig.isLocal(URL(string: "https://evil.lan.attacker.example/v1")!))  // review 5.9 N6
        #expect(AIConfig.isLocal(URL(string: "http://192.168.1.5:11434/v1")!) && AIConfig.isLocal(URL(string: "http://localhost:1234")!))
        #expect(!AIConfig.isLocal(URL(string: "https://api.openai.com/v1")!))
        #expect(AIConfig.transportProblem(URL(string: "http://llm.example.ziti:4000/v1")!) == nil)
        #expect(AIConfig.transportProblem(URL(string: "http://192.168.1.5:11434/v1")!) != nil)  // ATS: HTTPS needed
        var c = AIConfig(enabled: true, endpoint: base)
        #expect(c.model(for: .classify) == "llm-fast" && c.model(for: .embed) == "embedding")
        c.setModel(" classifier ", for: .classify)
        #expect(c.model(for: .classify) == "classifier" && c.secretKey == "ai:llm.example.ziti:4000")
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "ai"), create: true)
        try AIConfigStore(layout: layout).save(c)
        #expect(AIConfigStore(layout: layout).load() == c)
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.root.appending(path: "ai.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func endpointAnswersAndSendsWhatItShould() async throws {
        StubProtocol.load([.init(status: 200, body: completion("```json\n{\"query\":\"from:amazon\",\"why\":null}\n```"))])
        let r = try await provider.chat(request, model: "llm-fast", attempt: 1)
        #expect(r.text == "{\"query\":\"from:amazon\",\"why\":null}" && r.path == .endpoint && r.promptTokens == 12)
        let sent = try #require(StubProtocol.seen.withLock { $0.first })
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "llm-fast" && body["temperature"] as? Int == 0)
        #expect(((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["strict"] as? Bool == true)
    }

    @Test func truncatedAndBadAnswersAreErrors() async throws {
        StubProtocol.load([.init(status: 200, body: completion(nil, finish: "length"))])
        await #expect(throws: AIError.truncated) { _ = try await provider.chat(request, model: "llm-fast", attempt: 1) }
        StubProtocol.load([.init(status: 401, body: #"{"error":{"message":"Authentication Error, LiteLLM Virtual Key expected.‮"}}"#)])
        do {
            _ = try await provider.chat(request, model: "llm-fast", attempt: 1)
            Issue.record("no error")
        } catch let error as AIError {
            guard case .server(401, let text) = error else { Issue.record("\(error)"); return }
            #expect(text == "Authentication Error, LiteLLM Virtual Key expected.")  // bidi control removed
        }
    }

    @Test func connectionFailuresAndOverloadGetOneMoreTryTimeoutsDoNot() async throws {
        StubProtocol.load([.init(status: 503, body: "busy"), .init(status: 200, body: completion("{\"query\":\"x\",\"why\":null}"))])
        _ = try await provider.chat(request, model: "llm-fast", attempt: 1)
        #expect(StubProtocol.seen.withLock { $0.count } == 2)
        StubProtocol.load([.init(status: 0, body: "", error: .timedOut), .init(status: 200, body: completion("{}"))])
        await #expect(throws: AIError.timeout(5)) { _ = try await provider.chat(request, model: "llm-fast", attempt: 1) }
        #expect(StubProtocol.seen.withLock { $0.count } == 1)  // the server is still generating: no second request
    }

    @Test func routerFallsBackToTheMacWhenTheEndpointIsAwayAndLogsNoContent() async throws {
        let log = AICallLog(url: tempDir().appending(path: "ai.jsonl"))
        let router = AIRouter(config: AIConfig(enabled: true, endpoint: base), endpoint: provider,
                              onDevice: FakeOnDevice(answer: "{\"query\":\"from:mac\",\"why\":null}"), log: log)
        StubProtocol.load([.init(status: 0, body: "", error: .cannotConnectToHost), .init(status: 0, body: "", error: .cannotConnectToHost)])
        let first = try await router.chat(request)
        #expect(first.path == .onDevice)
        StubProtocol.load([])
        _ = try await router.chat(request)  // endpoint paused for a minute: straight to the Mac
        #expect(StubProtocol.seen.withLock { $0.isEmpty })
        let entries = log.entries()
        #expect(entries.map(\.outcome) == ["connection", "ok", "ok"] && entries.map(\.path) == [.endpoint, .onDevice, .onDevice])
        let raw = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!raw.contains("GEHEIM") && !raw.contains("from:mac"))
    }

    @Test func aWrongAnswerFromTheEndpointIsNotHiddenByTheFallback() async throws {
        let router = AIRouter(config: AIConfig(enabled: true, endpoint: base), endpoint: provider,
                              onDevice: FakeOnDevice(answer: "{}"), log: AICallLog(url: tempDir().appending(path: "ai.jsonl")))
        StubProtocol.load([.init(status: 400, body: #"{"error":{"message":"model not allowed"}}"#)])
        await #expect(throws: AIError.self) { _ = try await router.chat(request) }
        let off = AIRouter(config: AIConfig(enabled: false, endpoint: base), endpoint: provider, onDevice: nil,
                           log: AICallLog(url: tempDir().appending(path: "ai2.jsonl")))
        await #expect(throws: AIError.notConfigured) { _ = try await off.chat(request) }
    }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mk-ai-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Real models, opt-in: MAILKEEPER_AI=1 swift test --filter AILive
/// Endpoint and key name from ~/.config/mailkeeper/test-accounts.json ("llm"), key via `security`.
@Suite("AILive (real models)", .enabled(if: ProcessInfo.processInfo.environment["MAILKEEPER_AI"] == "1"), .serialized)
struct AILiveTests {
    static func config() throws -> (AIConfig, String) {
        struct File: Decodable {
            struct LLM: Decodable { struct KC: Decodable { let service: String; let account: String }; let baseURL: String; let keychain: KC }
            let llm: LLM
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/mailkeeper/test-accounts.json")
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", file.llm.keychain.service, "-a", file.llm.keychain.account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let key = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        p.waitUntilExit()
        return (AIConfig(enabled: true, endpoint: URL(string: file.llm.baseURL)!), key)
    }

    @Test func connectionTest() async throws {
        let (config, key) = try Self.config()
        let report = await AIRouter(config: config, apiKey: key, log: AICallLog(url: tempDir().appending(path: "ai.jsonl"))).test()
        for line in report.lines { print("\(line.ok ? "✓" : "✗") \(line.title): \(line.detail)") }
        let failed = report.lines.filter { !$0.title.hasPrefix("Modell auf") && !$0.ok }.map(\.title)
        #expect(failed.isEmpty)
        #expect(report.models.contains("llm-fast") && report.models.contains("embedding"))
    }
}

@Suite("Embeddings im Hintergrund (5.7)", .serialized)
struct EmbeddingIndexerTests {
    /// A stub embedding model: "Newsletter" texts point one way, everything else another.
    static func embed(_ body: Data) -> StubProtocol.Reply {  // used by EmbedStubProtocol
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let inputs = json?["input"] as? [String] ?? []
        if inputs.count > 32 { return .init(status: 422, body: #"{"error":{"message":"batch size > maximum allowed batch size 32"}}"#) }
        if inputs.contains(where: \.isEmpty) { return .init(status: 400, body: #"{"error":{"message":"inputs cannot be empty"}}"#) }
        let data = inputs.enumerated().map { i, text -> [String: Any] in
            let v: [Double] = text.contains("Newsletter") ? [1, 0.05 * Double(i % 3), 0] : [0, 0, 1]
            return ["index": i, "embedding": v]
        }
        let out = try! JSONSerialization.data(withJSONObject: ["data": data])
        return .init(status: 200, body: String(decoding: out, as: UTF8.self))
    }

    @Test func vectorsFillAndAnOpenMailFollowsItsClearNeighbours() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "ix"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        var batch: [(data: Data, location: LocationInfo)] = (1...5).map { n in
            (sampleMessage(id: "<n\(n)@t.test>", subject: "Newsletter Woche \(n)", extraHeaders: "List-Id: <news.t.test>\n"),
             LocationInfo(account: "x", mailbox: "INBOX", providerID: "n\(n)"))
        }
        batch.append((sampleMessage(id: "<s@t.test>", subject: "Newsletter Spezialausgabe"), LocationInfo(account: "x", mailbox: "INBOX", providerID: "s")))
        batch.append((sampleMessage(id: "<g@t.test>", subject: "Grillen am Samstag"), LocationInfo(account: "x", mailbox: "INBOX", providerID: "g")))
        _ = try await writer.ingest(batch)
        _ = try await writer.classifyHeuristically()
        let provider = OpenAICompatibleProvider(baseURL: URL(string: "http://llm.example.ziti:4000/v1")!, apiKey: "sk", timeout: 5,
                                                protocolClasses: [EmbedStubProtocol.self])
        let router = AIRouter(config: AIConfig(enabled: true, endpoint: URL(string: "http://llm.example.ziti:4000/v1")!), endpoint: provider, onDevice: nil,
                              log: AICallLog(url: tempDir().appending(path: "l.jsonl")))
        var indexer = EmbeddingIndexer(router: router, writer: writer)
        indexer.batch = 3
        #expect(try await indexer.run() == 7)
        #expect(try await indexer.run() == 0)
        #expect(try await indexer.decideOpenBySimilarity() == 1)
        let r = try ArchiveReader(layout: layout)
        let subjects = { (q: String) in Set(try r.summaries(try r.messageIDs(MessageFilter(text: q + " "))).compactMap(\.subject)) }
        #expect(try subjects("kategorie:newsletter").contains("Newsletter Spezialausgabe"))
        #expect(try subjects("kategorie:offen") == ["Grillen am Samstag"])
    }
}

@Suite("Embedding backfill survives a short outage")
struct EmbeddingRetryTests {
    @Test func aBusyEndpointIsWaitedForARefusalIsNot() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "retry"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest((1...4).map { n in
            (sampleMessage(id: "<r\(n)@t.test>", subject: "Mail \(n)"), LocationInfo(account: "x", mailbox: "INBOX", providerID: "r\(n)"))
        })
        let base = URL(string: "http://llm.example.ziti:4000/v1")!
        let provider = OpenAICompatibleProvider(baseURL: base, apiKey: "sk", timeout: 5, protocolClasses: [FlakyEmbedStubProtocol.self])
        let router = AIRouter(config: AIConfig(enabled: true, endpoint: base), endpoint: provider, onDevice: nil,
                              log: AICallLog(url: tempDir().appending(path: "l.jsonl")))
        var indexer = EmbeddingIndexer(router: router, writer: writer)
        indexer.batch = 2
        indexer.retryDelays = [.milliseconds(10), .milliseconds(10)]
        FlakyEmbedStubProtocol.script.withLock { $0 = [500, 500, 200, 500, 200] }
        #expect(try await indexer.run() == 4)  // two failures in a row, then one: all waited out

        _ = try await writer.ingest([(sampleMessage(id: "<r9@t.test>", subject: "Mail 9"), LocationInfo(account: "x", mailbox: "INBOX", providerID: "r9"))])
        FlakyEmbedStubProtocol.script.withLock { $0 = [500, 500, 500] }
        await #expect(throws: AIError.self) { try await indexer.run() }  // more than retryDelays: gives up
        FlakyEmbedStubProtocol.script.withLock { $0 = [401] }
        await #expect(throws: AIError.self) { try await indexer.run() }  // a refusal: at once
        #expect(FlakyEmbedStubProtocol.script.withLock { $0.isEmpty })
    }
}

/// Answers /embeddings with the scripted status codes in turn (200 = vectors), then 200.
final class FlakyEmbedStubProtocol: URLProtocol, @unchecked Sendable {
    static let script = Mutex<[Int]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.script.withLock { $0.isEmpty ? 200 : $0.removeFirst() }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            stream.close()
        }
        let reply = status == 200 ? EmbeddingIndexerTests.embed(body) : StubProtocol.Reply(status: status, body: #"{"error":{"message":"busy"}}"#)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("AILive embeddings", .enabled(if: ProcessInfo.processInfo.environment["MAILKEEPER_AI"] == "1"), .serialized)
struct AILiveEmbeddingTests {
    @Test func meaningFindsTheRightMail() async throws {
        let (config, key) = try AILiveTests.config()
        let router = AIRouter(config: config, apiKey: key, log: AICallLog(url: tempDir().appending(path: "ai.jsonl")))
        let texts = [
            "Betreff: Ihre Jahresabrechnung 2025\nVon: Stadtwerke <rechnung@stadtwerke.example>\nIhr Stromverbrauch und der neue Abschlag.",
            "Betreff: Grillen am Samstag?\nVon: Max <max@familie.example>\nWir grillen ab 17 Uhr, kommt ihr?",
            "Betreff: Ihr Flug nach Rom\nVon: Lufthansa <buchung@lufthansa.example>\nIhre Bordkarte für LH 232 am 12. Mai.",
            "Betreff: Herbst-Sale\nVon: Shop <news@shop.example>\nBis zu 40 % auf Jacken.",
        ]
        let vectors = try await router.embed(texts)
        let index = VectorIndex(ids: [1, 2, 3, 4], dim: vectors[0].count, matrix: vectors.flatMap(VectorMath.normalized))
        for (query, expected) in [("Kosten für Energie", Int64(1)), ("Reise nach Italien", 3), ("Treffen mit der Familie", 2)] {
            let q = VectorMath.normalized(try await router.embed([query])[0])
            let best = index.nearest(to: q, k: 1)
            print("„\(query)“ → \(best.first?.id ?? -1) (\(String(format: "%.3f", best.first?.score ?? 0)))")
            #expect(best.first?.id == expected, "\(query)")
        }
    }
}

/// A small RFC 822 message (CRLF), like the core tests' helper.
func sampleMessage(id: String, subject: String, body: String = "Hallo", extraHeaders: String = "") -> Data {
    let s = "From: a@example.test\nTo: inbox@example.test\nSubject: \(subject)\nDate: Thu, 14 Mar 2019 10:00:00 +0100\nMessage-ID: \(id)\n\(extraHeaders)Content-Type: text/plain; charset=utf-8\n\n\(body)\n"
    return Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8)
}

/// Its own URLProtocol (suites run in parallel): answers /embeddings by computing vectors.
final class EmbedStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            stream.close()
        }
        let reply = EmbeddingIndexerTests.embed(body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Embeddings in Paketen", .serialized)
struct EmbeddingBatchTests {
    @Test func moreThan32TextsGoInSeveralRequestsAndEmptyOnesAreReplaced() async throws {
        let provider = OpenAICompatibleProvider(baseURL: URL(string: "http://llm.example.ziti:4000/v1")!, apiKey: "sk", timeout: 5,
                                                protocolClasses: [EmbedStubProtocol.self])
        let texts = (0..<70).map { $0 == 5 ? "  " : "Newsletter \($0)" }
        let vectors = try await provider.embed(texts, model: "embedding")
        #expect(vectors.count == 70)
        #expect(vectors[5] == [0, 0, 1])  // "(ohne Text)": no newsletter
    }
}

@Suite("Review 5.9: router and transport")
struct RouterReviewTests {
    @Test("S1: a paused endpoint is no 'not configured' — a run must not stop on it")
    func aPausedEndpointSaysWhy() async throws {
        let base = URL(string: "http://127.0.0.1:9/v1")!  // nothing listens: connection refused
        let router = AIRouter(config: AIConfig(enabled: true, endpoint: base, onDevice: false),
                              endpoint: OpenAICompatibleProvider(baseURL: base, apiKey: nil, timeout: 5), onDevice: nil,
                              log: AICallLog(url: tempDir().appending(path: "l.jsonl")))
        let request = ChatRequest(task: .classify, system: "s", user: "u")
        for _ in 0..<2 {  // the first call pauses the endpoint, the second meets the pause
            do {
                _ = try await router.chat(request)
                Issue.record("no error")
            } catch let error as AIError {
                #expect(error != .notConfigured, "\(error)")
                if case .connection = error {} else { Issue.record("expected the connection error, got \(error)") }
            }
        }
        #expect(await router.endpointPaused)
    }

    @Test("C4: an oversized answer is refused while it arrives")
    func anOversizedAnswerIsRefused() async throws {
        let base = URL(string: "http://litellm.example.ziti:4000/v1")!
        let provider = OpenAICompatibleProvider(baseURL: base, apiKey: nil, timeout: 5, protocolClasses: [HugeStubProtocol.self])
        await #expect(throws: AIError.badAnswer(String(localized: "Antwort zu groß"))) {
            _ = try await provider.chat(ChatRequest(task: .classify, system: "s", user: "u"), model: "m", attempt: 1)
        }
    }
}

/// Streams an endless-looking answer (5 MiB, above the 4 MiB chat limit), without a length header.
final class HugeStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: 0x20, count: 1 << 20)
        for _ in 0..<5 { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Antwortsprache (8.4)")
struct OutputLanguageTests {
    @Test("Die Antwort folgt der Sprache der App, nicht der des Prompts")
    func languageFollowsTheInterface() {
        #expect(OutputLanguage.name(for: "de") == "Deutsch")
        #expect(OutputLanguage.name(for: "en") == "English")
        #expect(OutputLanguage.name(for: "en-GB") == "English")
        #expect(OutputLanguage.name(for: "de-AT") == "Deutsch")
        // anything the app is not translated into falls back with the bundle, which offers
        // only de and en — an unknown code must still produce a language, never an empty one
        #expect(!OutputLanguage.name(for: "fr").isEmpty)
        #expect(!OutputLanguage.current.isEmpty)
    }
}

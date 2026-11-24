import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MailKeeperMCP

@Suite("mailkeeper-mcp: MCP über HTTP")
struct HTTPTests {
    @Test func theProtocolSubsetAnswersAsAClientExpects() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        let (status, initialize) = try await rpc(server, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                       "clientInfo": ["name": "test", "version": "1"]])
        #expect(status == 200 && initialize?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(initialize?["result"]?["capabilities"]?["tools"] != nil && initialize?["result"]?["serverInfo"]?["name"] == "mailkeeper-mcp")
        #expect(try await rpc(server, "initialize", ["protocolVersion": "1999-01-01"]).body?["result"]?["protocolVersion"] == "2025-06-18")
        let tools = try #require(try await rpc(server, "tools/list").body?["result"]?["tools"]?.array)
        #expect(tools.compactMap { $0["name"]?.string } == ["search", "fetch", "list_persons", "mail_thread", "mail_attachments", "summarize_correspondence"])
        for tool in tools {
            #expect(tool["annotations"]?["readOnlyHint"] == true && tool["annotations"]?["destructiveHint"] == false)
            #expect(tool["_meta"]?["v2"]?["risk"] == "read_only" && tool["_meta"]?["v2"]?["data_class"] == "personal")
            #expect(tool["outputSchema"] == nil && tool["inputSchema"]?["additionalProperties"] == false)
        }
        #expect(try await rpc(server, "ping").body?["result"] == [:])
        #expect(try await rpc(server, "resources/list").body?["error"]?["code"] == -32601)
        #expect(try await rpc(server, "tools/call", ["name": "delete_all"]).body?["error"]?["code"] == -32602)
    }

    @Test func theHTTPRulesHold() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        #expect(try await rpc(server, "ping", host: "evil.example:8727").status == 421)
        let notification: JSONValue = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        let headers = ["host": "mcp.mail.ziti:8727"]
        #expect(await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: notification.serialized())).status == 202)
        #expect(await server.handle(HTTPRequest(method: "GET", path: "/mcp", headers: headers, body: Data())).status == 405)
        #expect(await server.handle(HTTPRequest(method: "POST", path: "/other", headers: headers, body: Data())).status == 404)
        #expect(await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data("{oops".utf8))).status == 400)
        #expect(await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data("[{}]".utf8))).status == 400)
        var versioned = headers
        versioned["mcp-protocol-version"] = "2020-01-01"
        #expect(await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: versioned, body: notification.serialized())).status == 400)
    }

    /// Over a real socket, as Claude Code and the broker will talk to it.
    @Test func endToEndOverLoopback() async throws {
        let (_, archives) = try await twoArchives()
        let (ports, bound) = AsyncStream.makeStream(of: Int.self)
        let mcp = try testServer(archives: archives)
        let task = Task {
            try await HTTPServer.run(host: "127.0.0.1", port: 0, maxBody: 4_096, bound: { bound.yield($0) }) { request in
                // the loopback name stands in for the Ziti intercept here
                var r = request
                if r.header("host")?.hasPrefix("127.0.0.1:") == true { r.headers["host"] = "mcp.mail.ziti:8727" }
                return await mcp.handle(r)
            }
        }
        defer { task.cancel() }
        var waiting = ports.makeAsyncIterator()
        let port = try #require(await waiting.next())
        func post(_ body: Data, token: String? = directToken) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        let call: JSONValue = ["jsonrpc": "2.0", "id": "a1", "method": "tools/call",
                               "params": ["name": "search", "arguments": ["query": "Rechnung"]]]
        let (status, data): (Int, Data)
        do { (status, data) = try await post(call.serialized()) } catch { Issue.record("tools/call: \(error)"); return }
        let answer = try JSONValue.parse(data)
        #expect(status == 200 && answer["id"] == "a1" && answer["result"]?["isError"] == false)
        #expect(answer["result"]?["structuredContent"]?["text"]?.string?.hasPrefix("2 Treffer") == true)
        // announced too large: 413 before the body is read
        do { let (big, _) = try await post(Data(repeating: 0x20, count: 10_000)); #expect(big == 413) }
        catch let e as URLError where e.code == .networkConnectionLost { /* the server closed after its 413: also a refusal */ }
        // several requests on one connection, the second above curl's 100-continue threshold
        let padded: JSONValue = ["jsonrpc": "2.0", "id": 2, "method": "ping", "params": ["_meta": ["pad": .string(String(repeating: "x", count: 2_000))]]]
        let (pingStatus, pingData) = try await post(padded.serialized())
        let pong = try JSONValue.parse(pingData)
        #expect(pingStatus == 200 && pong["result"] == [:])
    }
}

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A plain TCP connection to 127.0.0.1 — for what URLSession cannot do (hold a place, drip).
private func rawConnect(_ port: Int) -> Int32 {
    #if canImport(Glibc)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    return ok == 0 ? fd : -1
}

@Suite("mailkeeper-mcp: Verbindungen begrenzt")
struct ConnectionLimitTests {
    func start(maxConnections: Int, requestTimeout: Duration) async throws -> (Task<Void, Error>, Int) {
        let (ports, bound) = AsyncStream.makeStream(of: Int.self)
        let task = Task {
            try await HTTPServer.run(host: "127.0.0.1", port: 0, maxConnections: maxConnections, requestTimeout: requestTimeout,
                                     bound: { bound.yield($0) }) { _ in .text(200, "ok") }
        }
        var it = ports.makeAsyncIterator()
        return (task, try #require(await it.next()))
    }

    func get(_ port: Int) async -> Int? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/healthz")!, timeoutInterval: 3)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    @Test func aHeldPlaceBlocksTheNextAndIsGivenBack() async throws {
        let (task, port) = try await start(maxConnections: 1, requestTimeout: .seconds(30))
        defer { task.cancel() }
        let held = rawConnect(port)
        #expect(held >= 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await get(port) != 200)  // over the limit: closed at once, the server lives on
        close(held)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await get(port) == 200)
    }

    @Test func aRequestThatNeverCompletesIsClosedAtItsDeadline() async throws {
        let (task, port) = try await start(maxConnections: 4, requestTimeout: .milliseconds(300))
        defer { task.cancel() }
        let fd = rawConnect(port)
        #expect(fd >= 0)
        let partial = Array("GET /healthz HTTP/1.1\r\nHost: x\r\n".utf8)  // the head never ends
        _ = partial.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let started = ContinuousClock.now
        let n = read(fd, &buffer, buffer.count)  // blocks until the server closes
        close(fd)
        #expect(n <= 0 && ContinuousClock.now - started < TimeBudget.linear(.seconds(3)))
    }
}

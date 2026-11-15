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

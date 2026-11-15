import Foundation
import Testing
@testable import MailKeeperServer

@Suite("mailkeeper-mcp: Konfiguration")
struct MCPSettingsTests {
    static let section = #"""
    {"listen": "127.0.0.1:8000", "health": "0.0.0.0:8080", "allowedHosts": ["mcp.mail.ziti:8727"], "audience": "mail",
     "jwksURL": "http://kastelain-gateway.kastelain/.well-known/jwks.json", "users": {"jan": "jan"},
     "directTokenFile": "/run/secrets/mailkeeper-mcp/direct-token", "directPerson": "jan", "timeZone": "Europe/Berlin",
     "ai": {"url": "http://litellm.litellm:4000/v1", "model": "llm-fast", "keyFile": "/run/secrets/mailkeeper-mcp/litellm-key"}}
    """#

    static func config(_ mcp: String?) -> String {
        """
        {"intervalSeconds": 900, "secretsDirectory": "/run/secrets/mailkeeper", "statusFile": "/data/status.json",
         \(mcp.map { "\"mcp\": \($0)," } ?? "")
         "people": [{"id": "jan", "archive": "/data/jan", "accounts": []}]}
        """
    }

    func load(_ json: String) throws -> ServerConfig {
        let c = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        try c.validate()
        return c
    }

    @Test func aValidSectionLoads() throws {
        let c = try load(Self.config(Self.section))
        #expect(c.mcp?.audience == "mail" && c.mcp?.users == ["jan": "jan"] && c.mcp?.ai?.timeoutSeconds == 180)
        #expect(try load(Self.config(nil)).mcp == nil)  // without the connector nothing changes
        #expect(MCPSettings.hostPort("[::1]:8000")! == ("::1", 8000) && MCPSettings.hostPort("mcp.mail.ziti:8727")! == ("mcp.mail.ziti", 8727))
    }

    @Test func mistakesAreRefusedBeforeAnythingRuns() {
        func refused(_ from: String, _ to: String, _ why: Comment) {
            #expect(throws: (any Error).self, why) { try load(Self.config(Self.section.replacingOccurrences(of: from, with: to))) }
        }
        refused(#""listen": "127.0.0.1:8000""#, #""listen": "0.0.0.0:8000""#, "not loopback: a cluster address bypasses the dial policy")
        refused(#""listen": "127.0.0.1:8000""#, #""listen": "10.0.0.5:8000""#, "pod address")
        refused(#""health": "0.0.0.0:8080""#, #""health": "0.0.0.0:8000""#, "same port as listen")
        refused(#""allowedHosts": ["mcp.mail.ziti:8727"]"#, #""allowedHosts": []"#, "no host")
        refused(#""allowedHosts": ["mcp.mail.ziti:8727"]"#, #""allowedHosts": ["mcp.mail.ziti"]"#, "host without port")
        refused(#""audience": "mail""#, #""audience": "Mail Archiv""#, "no register id")
        refused(#""jwksURL": "http://kastelain-gateway.kastelain/.well-known/jwks.json""#, #""jwksURL": "file:///etc/keys""#, "not http")
        refused(#""users": {"jan": "jan"}"#, #""users": {}"#, "nobody on the broker path")
        refused(#""users": {"jan": "jan"}"#, #""users": {"katja": "katja"}"#, "a person without an archive")
        refused(#""users": {"jan": "jan"}"#, #""users": {"jan; rm": "jan"}"#, "no LLDAP name")
        refused(#""directPerson": "jan""#, #""directPerson": "admin""#, "direct person without an archive")
        refused(#""directTokenFile": "/run/secrets/mailkeeper-mcp/direct-token""#, #""directTokenFile": "token""#, "relative")
        refused(#""directTokenFile": "/run/secrets/mailkeeper-mcp/direct-token""#, #""directTokenFile": "/data/jan/token""#, "inside an archive")
        refused(#""timeZone": "Europe/Berlin""#, #""timeZone": "Mars/Olympus""#, "unknown zone")
        refused(#""model": "llm-fast""#, #""model": " ""#, "no model")
        refused(#""model": "llm-fast""#, #""model": "llm-fast", "timeoutSeconds": 5"#, "timeout too short")
        refused(#""timeZone": "Europe/Berlin""#, #""timeZone": "Europe/Berlin", "debug": true"#, "unknown field")
    }
}

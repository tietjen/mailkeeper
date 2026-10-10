import CryptoKit
import Foundation

// Spike helper (unsandboxed CLI). A throwaway Ed25519 key for the local Sparkle test only —
// never the production Sparkle key.
//   s4tool keygen <keyfile>                         → prints the public key (SUPublicEDKey)
//   s4tool appcast <keyfile> <archive> <url> <version> <out.xml>

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: s4tool keygen <keyfile> | appcast <keyfile> <archive> <url> <version> <out.xml>")
    exit(2)
}

switch args[1] {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    let url = URL(fileURLWithPath: args[2])
    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    try key.rawRepresentation.base64EncodedData().write(to: url)
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "appcast" where args.count == 7:
    let raw = Data(base64Encoded: try Data(contentsOf: URL(fileURLWithPath: args[2])))!
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    let signature = try key.signature(for: archive).base64EncodedString()
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>S4 spike feed</title>
        <item>
          <title>Version \(args[5])</title>
          <sparkle:version>\(args[5])</sparkle:version>
          <sparkle:shortVersionString>0.0.\(args[5])</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
          <enclosure url="\(args[4])" length="\(archive.count)" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
        </item>
      </channel>
    </rss>
    """
    try xml.write(toFile: args[6], atomically: true, encoding: .utf8)
    print("appcast: version \(args[5]), \(archive.count) bytes, signed")

default:
    print("unknown command")
    exit(2)
}

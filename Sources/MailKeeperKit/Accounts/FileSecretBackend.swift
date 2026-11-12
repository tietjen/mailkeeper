import Foundation

/// Secrets as files in one directory — on the server a mounted Kubernetes secret
/// (mailkeeper-server). Read-only: the server is set up from GitOps, nothing it runs writes a
/// secret. A missing directory is a setup error and throws, never "no password".
///
/// The file name is the key with every character outside `A–Z a–z 0–9 . _ -` replaced by `_`
/// (`jan@example.org@mail.example.org:993` → `jan_example.org_mail.example.org_993`), which is
/// also a valid key of a Kubernetes secret. `mailkeeperd --secret-names` prints them.
public struct FileSecretBackend: SecretBackend {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func fileName(for key: String) -> String {
        let name = String(key.unicodeScalars.map { c -> Character in
            switch c {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": Character(c)
            default: "_"
            }
        })
        // No slash survives; "", "." and ".." would still name the folder or its parent.
        return ["", ".", ".."].contains(name) ? "_" + name : name
    }

    public func write(_ secret: Data, key: String, label: String, description: String) throws {
        throw AccountError.readOnlySecretStore
    }

    public func read(key: String) throws -> Data? {
        try requireDirectory()
        let url = directory.appending(path: Self.fileName(for: key))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var data = try Data(contentsOf: url)
        // Secret files often end in a newline (echo, editors); a password does not.
        while data.last == 0x0A || data.last == 0x0D { data.removeLast() }
        // An empty file is no password: no login with "" (fail2ban counts that too).
        return data.isEmpty ? nil : data
    }

    public func exists(key: String) throws -> Bool {
        try requireDirectory()
        return FileManager.default.fileExists(atPath: directory.appending(path: Self.fileName(for: key)).path)
    }

    public func delete(key: String) throws {
        throw AccountError.readOnlySecretStore
    }

    private func requireDirectory() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AccountError.noSecretStore
        }
    }
}

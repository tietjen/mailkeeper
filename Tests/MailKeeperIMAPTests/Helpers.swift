import Foundation

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mk-imap-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

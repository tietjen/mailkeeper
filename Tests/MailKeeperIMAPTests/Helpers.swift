import Foundation

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mk-imap-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The line an ESEARCH server sends for these UIDs (sorted, distinct): consecutive UIDs
/// joined into ranges, as `* ESEARCH (TAG "A123") UID ALL 1:5,7,9:12` plus CRLF.
func esearchLine(_ uids: [UInt32]) -> String {
    var parts: [String] = []
    var i = 0
    while i < uids.count {
        var j = i
        while j + 1 < uids.count, uids[j + 1] == uids[j] + 1 { j += 1 }
        parts.append(i == j ? "\(uids[i])" : "\(uids[i]):\(uids[j])")
        i = j + 1
    }
    return "* ESEARCH (TAG \"A123\") UID ALL " + parts.joined(separator: ",") + "\r\n"
}

/// Small seeded generator: random test shapes that repeat on every run.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

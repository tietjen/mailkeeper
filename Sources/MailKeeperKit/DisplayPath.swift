import Foundation

/// A path the way the user finds it in Finder: the real home folder shortened to `~`.
///
/// `abbreviatingWithTildeInPath` goes by `NSHomeDirectory()`, and in the App Sandbox that is
/// the app's container. The release app showed `~/Library/Logs/MailKeeper/audit.jsonl` for a
/// log that really lies in `~/Library/Containers/de.paranoidsecurity.MailKeeper/Data/Library/
/// Logs/MailKeeper/`, and a folder the user picked in their own home kept its full path.
public enum DisplayPath {
    public static func tilde(_ path: String, home: String = realHome) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The user's home from the user database: the same inside and outside the sandbox.
    /// `getpwuid_r` with a buffer of our own — `getpwuid` would overwrite the calling thread's
    /// copy, which a library must not do to its caller.
    public static var realHome: String {
        var buffer = [CChar](repeating: 0, count: max(sysconf(Int32(_SC_GETPW_R_SIZE_MAX)), 4096))
        // pw_dir points into the buffer: read it while the buffer is pinned, not after.
        let home: String? = buffer.withUnsafeMutableBufferPointer { buf in
            var entry = passwd()
            var found: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(getuid(), &entry, buf.baseAddress!, buf.count, &found) == 0,  // non-optional on Linux
                  found != nil, let dir = entry.pw_dir else { return nil }
            return String(cString: dir)
        }
        return home ?? NSHomeDirectory()
    }
}

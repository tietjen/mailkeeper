import Foundation

#if os(Linux)
extension String {
    /// Linux's Foundation has no `String(localized:)` and no string catalogs. The server speaks
    /// the source language (German); interpolations format as in any string. Public so IMAP,
    /// AI and mkctl use the same stand-in.
    public init(localized value: String, comment: StaticString? = nil) {
        self = value
    }
}
#endif

/// `SOCK_STREAM` is an `Int32` on Darwin and an enum in Glibc.
let socketStream: Int32 = {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}()

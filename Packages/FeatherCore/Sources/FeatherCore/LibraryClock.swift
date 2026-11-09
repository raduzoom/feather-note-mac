import Foundation

/// The source of "now" for a library, in milliseconds since the Unix epoch.
public struct LibraryClock: Sendable {
    public var now: @Sendable () -> Int64

    public init(now: @escaping @Sendable () -> Int64) { self.now = now }

    public static let system = LibraryClock { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    public static func fixed(_ ms: Int64) -> LibraryClock { LibraryClock { ms } }
}

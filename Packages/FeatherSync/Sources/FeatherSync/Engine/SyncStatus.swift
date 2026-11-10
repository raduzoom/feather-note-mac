import Foundation

/// What the sidebar footer shows about sync (ui-copy.md "Sync status lines").
public enum SyncStatus: Equatable, Sendable {
    case idle(lastSynced: Date?)
    case syncing(done: Int, total: Int)
    case offline
    /// The plan is read-only: changes stay here, pulls continue.
    case readOnly
    /// A change didn't fit the quota; it stays here until there is room.
    case quotaFull
    case error(String)
    /// The server ended the session (401): the app signs out and keeps its notes.
    case signedOut
}

/// What one pass did.
public struct SyncReport: Equatable, Sendable {
    public var pushed = 0
    public var pulled = 0
    public var conflictCopies: [ULIDText] = []
    public var nameConflicts = 0
    /// Rejected changes: item id → error code. They stay dirty.
    public var rejected: [String: String] = [:]
    public var readOnly = false
    public var quotaFull = false
    public init() {}
}

public typealias ULIDText = String

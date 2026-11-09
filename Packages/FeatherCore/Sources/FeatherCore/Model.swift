/// The kind of a synced item (data-model.md "Entities").
public enum ItemType: String, Sendable {
    case note, notebook, tag, attachment
}

/// What a change-log row records: the item was created or changed, or deleted for good.
public enum ChangeOp: String, Sendable {
    case upsert, delete
}

public struct Notebook: Sendable, Equatable, Identifiable {
    public var id: ULID
    public var name: String
    public var parentID: ULID?
    public var created: Int64
    public var modified: Int64
}

public struct Tag: Sendable, Equatable, Identifiable {
    public var id: ULID
    public var name: String
    public var created: Int64
    public var modified: Int64
}

public struct ChangeLogEntry: Sendable, Equatable {
    public var seq: Int64
    public var itemID: ULID
    public var itemType: ItemType
    public var op: ChangeOp
    public var bodyChanged: Bool
    public var at: Int64
}

public struct Note: Sendable, Equatable, Identifiable {
    public var id: ULID
    public var title: String
    public var body: String
    public var notebookID: ULID?
    public var tagIDs: Set<ULID>
    public var pinned: Bool
    public var created: Int64
    /// Last change to title or body.
    public var modified: Int64
    public var trashedAt: Int64?
}

/// A note as shown in a list: no full body.
public struct NoteSummary: Sendable, Equatable, Identifiable {
    public var id: ULID
    public var title: String
    /// The first 200 characters of the body, whitespace runs collapsed to one space.
    public var preview: String
    public var notebookID: ULID?
    public var pinned: Bool
    public var modified: Int64
    public var trashedAt: Int64?
}

public enum NoteScope: Sendable, Equatable {
    case all, recent, pinned, trash
    /// Includes sub-notebooks.
    case notebook(ULID)
    case tag(ULID)
}

public struct Attachment: Sendable, Equatable, Identifiable {
    public var id: ULID
    public var filename: String
    public var mime: String
    /// Plaintext size in bytes.
    public var size: Int64
    /// SHA-256 of the content, lowercase hex.
    public var sha256: String
    public var created: Int64
}

public struct SearchHit: Sendable, Equatable {
    public var note: NoteSummary
    /// A short excerpt of the body around the matches (the preview when only the title matched).
    public var snippet: String
    /// Character offsets of each match inside `snippet`.
    public var matches: [Range<Int>]
}

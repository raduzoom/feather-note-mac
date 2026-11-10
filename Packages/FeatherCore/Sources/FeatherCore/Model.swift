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

    public init(id: ULID, name: String, parentID: ULID?, created: Int64, modified: Int64) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.created = created
        self.modified = modified
    }
}

public struct Tag: Sendable, Equatable, Identifiable {
    public var id: ULID
    public var name: String
    public var created: Int64
    public var modified: Int64

    public init(id: ULID, name: String, created: Int64, modified: Int64) {
        self.id = id
        self.name = name
        self.created = created
        self.modified = modified
    }
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

    public init(id: ULID, title: String, body: String, notebookID: ULID?, tagIDs: Set<ULID>, pinned: Bool, created: Int64,
                modified: Int64, trashedAt: Int64?) {
        self.id = id
        self.title = title
        self.body = body
        self.notebookID = notebookID
        self.tagIDs = tagIDs
        self.pinned = pinned
        self.created = created
        self.modified = modified
        self.trashedAt = trashedAt
    }
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

    public init(id: ULID, title: String, preview: String, notebookID: ULID?, pinned: Bool, modified: Int64, trashedAt: Int64?) {
        self.id = id
        self.title = title
        self.preview = preview
        self.notebookID = notebookID
        self.pinned = pinned
        self.modified = modified
        self.trashedAt = trashedAt
    }
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

    public init(id: ULID, filename: String, mime: String, size: Int64, sha256: String, created: Int64) {
        self.id = id
        self.filename = filename
        self.mime = mime
        self.size = size
        self.sha256 = sha256
        self.created = created
    }
}

public struct SearchHit: Sendable, Equatable {
    public var note: NoteSummary
    /// A short excerpt of the body around the matches (the preview when only the title matched).
    public var snippet: String
    /// Character offsets of each match inside `snippet`.
    public var matches: [Range<Int>]
}

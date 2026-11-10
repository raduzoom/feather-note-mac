import Foundation

/// What an importer (ENEX, Notion, …) produces: notebooks, notes and attachment files on disk, written by
/// `Library.importBundle` in one transaction (universal/specs/import-formats.md).
public struct ImportBundle: Sendable {
    // nested types, so they don't clash with FeatherCore's own Notebook and Note
    public struct Notebook: Sendable, Equatable {
        public var key: String
        public var name: String
        public var parentKey: String?
        public init(key: String, name: String, parentKey: String?) {
            self.key = key
            self.name = name
            self.parentKey = parentKey
        }
    }

    public struct Note: Sendable, Equatable {
        public var title: String
        /// Refers to attachments as `feather-import://<token>`.
        public var body: String
        public var notebookKey: String?
        public var tags: [String]
        public var created: Int64?
        public var modified: Int64?
        public var attachments: [AttachmentFile]
        public var preserved: [PreservedContent.Kind]
        public init(title: String, body: String, notebookKey: String?, tags: [String] = [], created: Int64? = nil,
                    modified: Int64? = nil, attachments: [AttachmentFile] = [], preserved: [PreservedContent.Kind] = []) {
            self.title = title
            self.body = body
            self.notebookKey = notebookKey
            self.tags = tags
            self.created = created
            self.modified = modified
            self.attachments = attachments
            self.preserved = preserved
        }
    }

    public var notebooks: [ImportBundle.Notebook]
    public var notes: [ImportBundle.Note]
    /// Links left as written (e.g. Obsidian `[[note]]`), for the report.
    public var keptAsWritten: Int
    /// Temporary folder holding attachment files; removed after the import, whatever happens.
    public var scratch: URL?

    public init(notebooks: [ImportBundle.Notebook], notes: [ImportBundle.Note], keptAsWritten: Int = 0, scratch: URL? = nil) {
        self.notebooks = notebooks
        self.notes = notes
        self.keptAsWritten = keptAsWritten
        self.scratch = scratch
    }

    public static let tokenScheme = "feather-import://"
}

public struct AttachmentFile: Sendable, Equatable {
    public var token: String
    public var file: URL
    public var filename: String
    public var mime: String?
    public init(token: String, file: URL, filename: String, mime: String?) {
        self.token = token
        self.file = file
        self.filename = filename
        self.mime = mime
    }
}

/// Content kept verbatim because it has no Markdown form; listed in the import report.
public struct PreservedContent: Sendable, Equatable {
    public enum Kind: String, Sendable { case table, html, encrypted, notionBlock }
    public var noteID: ULID
    public var title: String
    public var kind: Kind
    public init(noteID: ULID, title: String, kind: Kind) {
        self.noteID = noteID
        self.title = title
        self.kind = kind
    }
}

public struct ImportProgress: Sendable, Equatable {
    public var notesDone: Int
    public var notesTotal: Int
    public var attachments: Int
    /// Title of the note just imported.
    public var current: String
    public init(notesDone: Int, notesTotal: Int, attachments: Int, current: String) {
        self.notesDone = notesDone
        self.notesTotal = notesTotal
        self.attachments = attachments
        self.current = current
    }
}

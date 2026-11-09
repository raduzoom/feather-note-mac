enum Schema {
    static let version = 2

    /// Migration `i` takes the database from version `i` to `i + 1`.
    static let migrations: [String] = [
        """
        CREATE TABLE library (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE notebooks (
          id TEXT PRIMARY KEY, name TEXT NOT NULL,
          parent_id TEXT REFERENCES notebooks(id) ON DELETE CASCADE,
          created INTEGER NOT NULL, modified INTEGER NOT NULL);
        CREATE INDEX notebooks_parent ON notebooks(parent_id);
        CREATE TABLE tags (
          id TEXT PRIMARY KEY, name TEXT NOT NULL, name_key TEXT NOT NULL UNIQUE,
          created INTEGER NOT NULL, modified INTEGER NOT NULL);
        CREATE TABLE notes (
          rowid INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, title TEXT NOT NULL, body TEXT NOT NULL,
          notebook_id TEXT REFERENCES notebooks(id) ON DELETE SET NULL,
          pinned INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL, modified INTEGER NOT NULL,
          trashed_at INTEGER);
        CREATE INDEX notes_notebook ON notes(notebook_id);
        CREATE INDEX notes_modified ON notes(modified);
        CREATE TABLE note_tags (
          note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
          tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
          PRIMARY KEY (note_id, tag_id)) WITHOUT ROWID;
        CREATE INDEX note_tags_tag ON note_tags(tag_id);
        CREATE TABLE attachments (
          id TEXT PRIMARY KEY, filename TEXT NOT NULL, mime TEXT NOT NULL,
          size INTEGER NOT NULL, sha256 TEXT NOT NULL, created INTEGER NOT NULL);
        CREATE TABLE change_log (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT NOT NULL, item_type TEXT NOT NULL,
          op TEXT NOT NULL CHECK (op IN ('upsert','delete')), body_changed INTEGER NOT NULL, at INTEGER NOT NULL);
        CREATE VIRTUAL TABLE notes_fts USING fts5(
          title, body, content='notes', content_rowid='rowid',
          tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
        END;
        CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
        END;
        CREATE TRIGGER notes_au AFTER UPDATE OF title, body ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
        END;
        """,
        // v2: counts and list filters read only this index, never the note rows with their bodies.
        """
        CREATE INDEX notes_state ON notes(trashed_at, pinned, notebook_id);
        """,
    ]

    static func userVersion(_ db: Connection) throws -> Int {
        let s = try db.prepare("PRAGMA user_version")
        _ = try s.step()
        return Int(s.int64(0))
    }

    /// Brings the database to `version`. Throws `newerSchema` before writing anything
    /// if the file is newer than this code.
    static func migrate(_ db: Connection) throws {
        let found = try userVersion(db)
        if found > version { throw LibraryError.newerSchema(found: found, supported: version) }
        guard found < version else { return }
        try db.transaction {
            for v in found..<version {
                try db.execute(migrations[v])
            }
            try db.execute("PRAGMA user_version = \(version)")
        }
    }
}

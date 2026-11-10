import Foundation

/// One item's sync bookkeeping (sync-protocol.md "Client sync algorithm": the server version last seen and a
/// dirty flag set by every local change).
public struct SyncItem: Sendable, Equatable {
    public var id: ULID
    public var type: ItemType
    public var serverVersion: Int64
    /// The change-log seq of the latest local change not yet pushed; nil when clean.
    public var dirtySeq: Int64?
    /// The body (notes) or content (attachments) changed and needs a new blob.
    public var bodyDirty: Bool
    /// Deleted locally for good: push a tombstone.
    public var deleted: Bool
    /// SHA-256 of the encrypted blob last uploaded or downloaded.
    public var blobSHA: String?
    /// Metadata fields this client doesn't know, as a JSON object, written back unchanged.
    public var extraMeta: String?
    /// The metadata `v`; above 1 the item is read-only here.
    public var metaVersion: Int
}

/// A notebook or tag rename that lost to the server's (Settings › Sync conflicts).
public struct SyncConflict: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var itemID: ULID
    public var type: ItemType
    public var lostName: String
    public var device: String
    public var at: Int64
}

extension Library {
    static func syncItem(_ s: Statement) -> SyncItem {
        SyncItem(id: s.ulid(0), type: ItemType(rawValue: s.text(1))!, serverVersion: s.int64(2), dirtySeq: s.optionalInt64(3),
                 bodyDirty: s.int64(4) != 0, deleted: s.int64(5) != 0, blobSHA: s.optionalText(6), extraMeta: s.optionalText(7),
                 metaVersion: Int(s.int64(8)))
    }

    static let syncColumns = "item_id, item_type, server_version, dirty_seq, body_dirty, deleted, blob_sha, extra_meta, meta_version"

    // MARK: Local changes

    /// Turns change-log rows after `log_seq` into dirty items. Returns how many items became dirty.
    @discardableResult
    public func collectChanges() throws -> Int {
        try write { db in
            let after = Int64(try syncValue("log_seq", in: db) ?? "0") ?? 0
            let entries = try db.all("SELECT seq, item_id, item_type, op, body_changed FROM change_log WHERE seq > ? ORDER BY seq",
                                     [.int(after)]) { s in
                (seq: s.int64(0), id: s.text(1), type: s.text(2), delete: s.text(3) == "delete", body: s.int64(4) != 0)
            }
            guard let last = entries.last else { return 0 }
            var touched: Set<String> = []
            for e in entries {
                try db.run("""
                    INSERT INTO sync_items (item_id, item_type, dirty_seq, body_dirty, deleted) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(item_id) DO UPDATE SET dirty_seq = excluded.dirty_seq,
                      body_dirty = MAX(body_dirty, excluded.body_dirty), deleted = excluded.deleted
                    """, [.text(e.id), .text(e.type), .int(e.seq), .int(e.body ? 1 : 0), .int(e.delete ? 1 : 0)])
                touched.insert(e.id)
            }
            try setSyncValue("log_seq", String(last.seq), in: db)
            return touched.count
        }
    }

    public func dirtyItems() throws -> [SyncItem] {
        try db.all("SELECT \(Self.syncColumns) FROM sync_items WHERE dirty_seq IS NOT NULL ORDER BY dirty_seq", [], Self.syncItem)
    }

    public func syncItem(_ id: ULID) throws -> SyncItem? {
        try db.all("SELECT \(Self.syncColumns) FROM sync_items WHERE item_id = ?", [.id(id)], Self.syncItem).first
    }

    /// Records an accepted push. The item becomes clean only if nothing changed since the snapshot `ifDirtySeq`.
    public func markPushed(_ id: ULID, version: Int64, blobSHA: String?, ifDirtySeq: Int64) throws {
        try write { db in
            try db.run("UPDATE sync_items SET server_version = ?, blob_sha = COALESCE(?, blob_sha) WHERE item_id = ?",
                       [.int(version), blobSHA.map(SQLValue.text) ?? .null, .id(id)])
            try db.run("UPDATE sync_items SET dirty_seq = NULL, body_dirty = 0 WHERE item_id = ? AND dirty_seq = ?",
                       [.id(id), .int(ifDirtySeq)])
            // a pushed tombstone is done: forget the row
            try db.run("DELETE FROM sync_items WHERE item_id = ? AND deleted = 1 AND dirty_seq IS NULL", [.id(id)])
        }
    }

    /// Moves a dirty item onto a newer server version without clearing it, so its next push is based on that
    /// version (a local edit against a server tombstone: sync-protocol.md "Notes" rule 3).
    public func rebase(_ id: ULID, version: Int64) throws {
        try write { db in
            // the server may have dropped the blob with the tombstone: upload the body again
            try db.run("UPDATE sync_items SET server_version = ?, deleted = 0, body_dirty = 1 WHERE item_id = ?", [.int(version), .id(id)])
        }
    }

    // MARK: State

    public func syncValue(_ key: String) throws -> String? { try syncValue(key, in: db) }

    func syncValue(_ key: String, in db: Connection) throws -> String? {
        try db.all("SELECT value FROM sync_state WHERE key = ?", [.text(key)]) { $0.text(0) }.first
    }

    public func setSyncValue(_ key: String, _ value: String?) throws {
        try write { db in try setSyncValue(key, value, in: db) }
    }

    func setSyncValue(_ key: String, _ value: String?, in db: Connection) throws {
        if let value {
            try db.run("INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM sync_state WHERE key = ?", [.text(key)])
        }
    }

    /// Forgets all sync bookkeeping (sign-out). With `markAllDirty`, every item is new to the server (sign-in merge).
    public func resetSync(markAllDirty: Bool) throws {
        try write { db in
            let logSeq = try db.all("SELECT COALESCE(MAX(seq), 0) FROM change_log", []) { $0.int64(0) }.first ?? 0
            try db.run("DELETE FROM sync_items")
            try db.run("DELETE FROM sync_state")
            try db.run("DELETE FROM sync_conflicts")
            try setSyncValue("log_seq", String(logSeq), in: db)
            guard markAllDirty else { return }
            for (table, type, body) in [("notebooks", "notebook", 0), ("tags", "tag", 0), ("attachments", "attachment", 1), ("notes", "note", 1)] {
                try db.run("""
                    INSERT INTO sync_items (item_id, item_type, dirty_seq, body_dirty) SELECT id, '\(type)', ?, \(body) FROM \(table)
                    """, [.int(logSeq)])
            }
        }
    }

    /// The body or content must be uploaded again (the server answered blob_missing). Keeps the item dirty.
    public func markBodyDirty(_ id: ULID) throws {
        try write { db in
            let seq = try db.all("SELECT COALESCE(MAX(seq), 0) FROM change_log", []) { $0.int64(0) }.first ?? 0
            try db.run("UPDATE sync_items SET body_dirty = 1, dirty_seq = COALESCE(dirty_seq, ?) WHERE item_id = ?", [.int(seq), .id(id)])
        }
    }

    /// Whether a note's notebook and tags all exist here (pulls apply notes before later-renamed references).
    public func referencesResolve(notebookID: ULID?, tagIDs: Set<ULID>) throws -> Bool {
        if notebookID != nil, try !exists("notebooks", notebookID, in: db) { return false }
        for t in tagIDs where try !exists("tags", t, in: db) { return false }
        return true
    }

    // MARK: Remote changes (never logged)

    /// A remote write goes ahead only if this Mac hasn't changed the item since the engine looked at it: no
    /// change-log row it hasn't collected, and the dirty state it saw (`nil` = clean).
    private func unchangedHere(_ id: ULID, expecting dirtySeq: Int64?, in db: Connection) throws -> Bool {
        let logSeq = Int64(try syncValue("log_seq", in: db) ?? "0") ?? 0
        let unseen = try !db.all("SELECT 1 FROM change_log WHERE item_id = ? AND seq > ? LIMIT 1", [.id(id), .int(logSeq)]) { _ in true }.isEmpty
        let current = try db.all("SELECT dirty_seq FROM sync_items WHERE item_id = ?", [.id(id)]) { $0.optionalInt64(0) }.first ?? nil
        return !unseen && current == dirtySeq
    }

    private func remember(_ id: ULID, _ type: ItemType, version: Int64, blobSHA: String?, extraMeta: String?, metaVersion: Int,
                          in db: Connection) throws {
        try db.run("""
            INSERT INTO sync_items (item_id, item_type, server_version, dirty_seq, body_dirty, deleted, blob_sha, extra_meta, meta_version)
            VALUES (?, ?, ?, NULL, 0, 0, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET server_version = excluded.server_version, dirty_seq = NULL, body_dirty = 0, deleted = 0,
              blob_sha = COALESCE(excluded.blob_sha, blob_sha), extra_meta = excluded.extra_meta, meta_version = excluded.meta_version
            """, [.id(id), .text(type.rawValue), .int(version), blobSHA.map(SQLValue.text) ?? .null,
                  extraMeta.map(SQLValue.text) ?? .null, .int(Int64(metaVersion))])
    }

    private func exists(_ table: String, _ id: ULID?, in db: Connection) throws -> Bool {
        guard let id else { return false }
        return try !db.all("SELECT 1 FROM \(table) WHERE id = ?", [.id(id)]) { _ in true }.isEmpty
    }

    /// Stores a note from the server. A notebook that doesn't exist here puts it at the root; unknown tag ids are
    /// skipped (data-model.md "Trash").
    @discardableResult
    public func applyRemote(note: Note, version: Int64, blobSHA: String?, extraMeta: String?, metaVersion: Int, ifDirtySeq: Int64? = nil) throws -> Bool {
        try write { db in
            guard try unchangedHere(note.id, expecting: ifDirtySeq, in: db) else { return false }
            let notebook = try exists("notebooks", note.notebookID, in: db) ? note.notebookID : nil
            if try exists("notes", note.id, in: db) {
                try db.run("UPDATE notes SET title = ?, body = ?, notebook_id = ?, pinned = ?, created = ?, modified = ?, trashed_at = ? WHERE id = ?",
                           [.text(note.title), .text(note.body), .id(notebook), .int(note.pinned ? 1 : 0), .int(note.created),
                            .int(note.modified), note.trashedAt.map(SQLValue.int) ?? .null, .id(note.id)])
                try db.run("DELETE FROM note_tags WHERE note_id = ?", [.id(note.id)])
            } else {
                try db.run("INSERT INTO notes (id, title, body, notebook_id, pinned, created, modified, trashed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                           [.id(note.id), .text(note.title), .text(note.body), .id(notebook), .int(note.pinned ? 1 : 0),
                            .int(note.created), .int(note.modified), note.trashedAt.map(SQLValue.int) ?? .null])
            }
            for tag in note.tagIDs where try exists("tags", tag, in: db) {
                try db.run("INSERT OR IGNORE INTO note_tags (note_id, tag_id) VALUES (?, ?)", [.id(note.id), .id(tag)])
            }
            try remember(note.id, .note, version: version, blobSHA: blobSHA, extraMeta: extraMeta, metaVersion: metaVersion, in: db)
            return true
        }
    }

    /// Stores a notebook from the server. A parent that doesn't exist here makes it top-level.
    @discardableResult
    public func applyRemote(notebook: Notebook, version: Int64, extraMeta: String?, metaVersion: Int, ifDirtySeq: Int64? = nil) throws -> Bool {
        try write { db in
            guard try unchangedHere(notebook.id, expecting: ifDirtySeq, in: db) else { return false }
            let parent = try exists("notebooks", notebook.parentID, in: db) ? notebook.parentID : nil
            try db.run("""
                INSERT INTO notebooks (id, name, parent_id, created, modified) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, parent_id = excluded.parent_id, created = excluded.created,
                  modified = excluded.modified
                """, [.id(notebook.id), .text(notebook.name), .id(parent), .int(notebook.created), .int(notebook.modified)])
            try remember(notebook.id, .notebook, version: version, blobSHA: nil, extraMeta: extraMeta, metaVersion: metaVersion, in: db)
            return true
        }
    }

    /// Stores a tag from the server. Another device may have created a tag with the same name: both are kept
    /// (the name key gets the id appended so it stays unique).
    @discardableResult
    public func applyRemote(tag: Tag, version: Int64, extraMeta: String?, metaVersion: Int, ifDirtySeq: Int64? = nil) throws -> Bool {
        try write { db in
            guard try unchangedHere(tag.id, expecting: ifDirtySeq, in: db) else { return false }
            var key = Self.tagKey(tag.name)
            let owners = try db.all("SELECT id FROM tags WHERE name_key = ?", [.text(key)]) { $0.ulid(0) }
            if owners.contains(where: { $0 != tag.id }) { key += "\u{0}" + tag.id.description }
            try db.run("""
                INSERT INTO tags (id, name, name_key, created, modified) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, name_key = excluded.name_key, created = excluded.created,
                  modified = excluded.modified
                """, [.id(tag.id), .text(tag.name), .text(key), .int(tag.created), .int(tag.modified)])
            try remember(tag.id, .tag, version: version, blobSHA: nil, extraMeta: extraMeta, metaVersion: metaVersion, in: db)
            return true
        }
    }

    /// Stores an attachment and its content from the server.
    @discardableResult
    public func applyRemote(attachment: Attachment, content: Data, version: Int64, blobSHA: String?, extraMeta: String?, metaVersion: Int, ifDirtySeq: Int64? = nil) throws -> Bool {
        let stored = try attachmentStore.put(content)
        return try write { db in
            guard try unchangedHere(attachment.id, expecting: ifDirtySeq, in: db) else { return false }
            var a = attachment
            a.sha256 = stored.sha256
            try db.run("""
                INSERT INTO attachments (id, filename, mime, size, sha256, created) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET filename = excluded.filename, mime = excluded.mime, size = excluded.size,
                  sha256 = excluded.sha256, created = excluded.created
                """, [.id(a.id), .text(a.filename), .text(a.mime), .int(a.size), .text(a.sha256), .int(a.created)])
            try remember(a.id, .attachment, version: version, blobSHA: blobSHA, extraMeta: extraMeta, metaVersion: metaVersion, in: db)
            return true
        }
    }

    /// Removes an item the server deleted for good (a tombstone), and its bookkeeping.
    @discardableResult
    public func applyRemoteDelete(_ id: ULID, type: ItemType, version: Int64, ifDirtySeq: Int64? = nil) throws -> Bool {
        try write { db in
            guard try unchangedHere(id, expecting: ifDirtySeq, in: db) else { return false }
            let table = ["note": "notes", "notebook": "notebooks", "tag": "tags", "attachment": "attachments"][type.rawValue]!
            try db.run("DELETE FROM \(table) WHERE id = ?", [.id(id)])
            try db.run("DELETE FROM sync_items WHERE item_id = ?", [.id(id)])
            return true
        }
    }

    // MARK: Conflicts

    /// The local side of a note conflict, saved as a new note (sync-protocol.md "Conflict resolution").
    public func createConflictCopy(of note: Note, title: String) throws -> Note {
        try write { db in
            let notebook = try exists("notebooks", note.notebookID, in: db) ? note.notebookID : nil
            var tags: Set<ULID> = []
            for t in note.tagIDs where try exists("tags", t, in: db) { tags.insert(t) }
            var copy = try createNote(title: title, body: note.body, notebookID: notebook, tagIDs: tags,
                                      created: note.created, modified: note.modified)
            if note.pinned { try setPinned(copy.id, true); copy.pinned = true }
            return copy
        }
    }

    public func recordSyncConflict(itemID: ULID, type: ItemType, lostName: String, device: String) throws {
        try write { db in
            try db.run("INSERT INTO sync_conflicts (item_id, item_type, lost_name, device, at) VALUES (?, ?, ?, ?, ?)",
                       [.id(itemID), .text(type.rawValue), .text(lostName), .text(device), .int(clock.now())])
        }
    }

    public func syncConflicts() throws -> [SyncConflict] {
        try db.all("SELECT id, item_id, item_type, lost_name, device, at FROM sync_conflicts ORDER BY at DESC, id DESC", []) { s in
            SyncConflict(id: s.int64(0), itemID: s.ulid(1), type: ItemType(rawValue: s.text(2))!, lostName: s.text(3),
                         device: s.text(4), at: s.int64(5))
        }
    }
}

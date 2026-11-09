import Foundation

extension Library {
    static let day: Int64 = 86_400_000
    static let recentDays: Int64 = 7
    static let recentLimit = 50

    public func createNote(title: String = "", body: String = "", notebookID: ULID? = nil, tagIDs: Set<ULID> = [],
                           id: ULID? = nil, created: Int64? = nil, modified: Int64? = nil) throws -> Note {
        try write { db in
            if let notebookID { try requireNotebook(notebookID, in: db) }
            for tag in tagIDs { try requireTag(tag, in: db) }
            let now = clock.now()
            let created = created ?? now
            let note = Note(id: id ?? ULID.generate(at: now), title: title, body: body, notebookID: notebookID, tagIDs: tagIDs,
                            pinned: false, created: created, modified: modified ?? created, trashedAt: nil)
            try db.run("INSERT INTO notes (id, title, body, notebook_id, pinned, created, modified, trashed_at) VALUES (?, ?, ?, ?, 0, ?, ?, NULL)",
                       [.id(note.id), .text(title), .text(body), .id(notebookID), .int(note.created), .int(note.modified)])
            try insertTags(tagIDs, for: note.id, in: db)
            try log(.note, note.id, .upsert, bodyChanged: true, in: db)
            return note
        }
    }

    public func note(_ id: ULID) throws -> Note? {
        try note(id, in: db)
    }

    func note(_ id: ULID, in db: Connection) throws -> Note? {
        guard var note = try db.all("SELECT id, title, body, notebook_id, pinned, created, modified, trashed_at FROM notes WHERE id = ?",
                                    [.id(id)], { s in
            Note(id: s.ulid(0), title: s.text(1), body: s.text(2), notebookID: s.optionalULID(3), tagIDs: [],
                 pinned: s.int64(4) != 0, created: s.int64(5), modified: s.int64(6), trashedAt: s.optionalInt64(7))
        }).first else { return nil }
        note.tagIDs = Set(try db.all("SELECT tag_id FROM note_tags WHERE note_id = ?", [.id(id)]) { $0.ulid(0) })
        return note
    }

    /// Changes title and/or body. `modified` moves only when one of them actually changes.
    @discardableResult
    public func updateNote(_ id: ULID, title: String? = nil, body: String? = nil) throws -> Note {
        try write { db in
            var note = try requireNote(id, in: db)
            let newTitle = title ?? note.title
            let newBody = body ?? note.body
            let titleChanged = !Self.sameBytes(newTitle, note.title)
            let bodyChanged = !Self.sameBytes(newBody, note.body)
            guard titleChanged || bodyChanged else { return note }
            note.title = newTitle
            note.body = newBody
            note.modified = clock.now()
            try db.run("UPDATE notes SET title = ?, body = ?, modified = ? WHERE id = ?",
                       [.text(newTitle), .text(newBody), .int(note.modified), .id(id)])
            try log(.note, id, .upsert, bodyChanged: bodyChanged, in: db)
            return note
        }
    }

    public func setPinned(_ id: ULID, _ pinned: Bool) throws {
        try changeMetadata(id) { note, db in
            guard note.pinned != pinned else { return false }
            try db.run("UPDATE notes SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .id(id)])
            return true
        }
    }

    public func moveNote(_ id: ULID, to notebookID: ULID?) throws {
        try changeMetadata(id) { note, db in
            guard note.notebookID != notebookID else { return false }
            if let notebookID { try requireNotebook(notebookID, in: db) }
            try db.run("UPDATE notes SET notebook_id = ? WHERE id = ?", [.id(notebookID), .id(id)])
            return true
        }
    }

    public func setTags(_ id: ULID, _ tagIDs: Set<ULID>) throws {
        try changeMetadata(id) { note, db in
            for tag in tagIDs { try requireTag(tag, in: db) }
            guard note.tagIDs != tagIDs else { return false }
            try db.run("DELETE FROM note_tags WHERE note_id = ?", [.id(id)])
            try insertTags(tagIDs, for: id, in: db)
            return true
        }
    }

    public func trashNote(_ id: ULID) throws {
        try changeMetadata(id) { note, db in
            guard note.trashedAt == nil else { return false }
            try db.run("UPDATE notes SET trashed_at = ? WHERE id = ?", [.int(clock.now()), .id(id)])
            return true
        }
    }

    public func restoreNote(_ id: ULID) throws {
        try changeMetadata(id) { note, db in
            guard note.trashedAt != nil else { return false }
            try db.run("UPDATE notes SET trashed_at = NULL WHERE id = ?", [.id(id)])
            return true
        }
    }

    public func deleteNotePermanently(_ id: ULID) throws {
        try write { db in
            _ = try requireNote(id, in: db)
            try deleteNote(id, in: db)
        }
    }

    /// Deletes every note in Trash. Returns how many.
    @discardableResult
    public func emptyTrash() throws -> Int {
        try write { db in
            let ids = try db.all("SELECT id FROM notes WHERE trashed_at IS NOT NULL", []) { $0.ulid(0) }
            for id in ids { try deleteNote(id, in: db) }
            return ids.count
        }
    }

    /// Deletes notes that have been in Trash for at least `retentionDays`. Returns how many.
    @discardableResult
    public func purgeExpiredTrash(retentionDays: Int = 30) throws -> Int {
        try write { db in
            let cutoff = clock.now() - Int64(retentionDays) * Self.day
            let ids = try db.all("SELECT id FROM notes WHERE trashed_at IS NOT NULL AND trashed_at <= ?", [.int(cutoff)]) { $0.ulid(0) }
            for id in ids { try deleteNote(id, in: db) }
            return ids.count
        }
    }

    public func notes(in scope: NoteScope) throws -> [NoteSummary] {
        let select = "SELECT id, title, substr(body, 1, 300), notebook_id, pinned, modified, trashed_at FROM notes"
        let live = "trashed_at IS NULL"
        let listOrder = "ORDER BY pinned DESC, modified DESC, id DESC"
        let sql: String
        var values: [SQLValue] = []
        switch scope {
        case .all:
            sql = "\(select) WHERE \(live) \(listOrder)"
        case .recent:
            sql = "\(select) WHERE \(live) AND modified >= ? ORDER BY modified DESC, id DESC LIMIT \(Self.recentLimit)"
            values = [.int(clock.now() - Self.recentDays * Self.day)]
        case .pinned:
            sql = "\(select) WHERE \(live) AND pinned = 1 ORDER BY modified DESC, id DESC"
        case .trash:
            sql = "\(select) WHERE trashed_at IS NOT NULL ORDER BY trashed_at DESC, id DESC"
        case .notebook(let id):
            let tree = try descendants(of: id, in: db)
            sql = "\(select) WHERE \(live) AND notebook_id IN (\(tree.map { _ in "?" }.joined(separator: ","))) \(listOrder)"
            values = tree.map { .id($0) }
            if tree.isEmpty { return [] }
        case .tag(let id):
            sql = "\(select) WHERE \(live) AND id IN (SELECT note_id FROM note_tags WHERE tag_id = ?) \(listOrder)"
            values = [.id(id)]
        }
        return try db.all(sql, values, Self.summary)
    }

    static func summary(_ s: Statement) -> NoteSummary {
        NoteSummary(id: s.ulid(0), title: s.text(1), preview: preview(s.text(2)), notebookID: s.optionalULID(3),
                    pinned: s.int64(4) != 0, modified: s.int64(5), trashedAt: s.optionalInt64(6))
    }

    /// Collapses whitespace runs to one space and keeps the first 200 characters.
    /// Works on UTF-8 bytes with an ASCII fast path: per-Character and Unicode-property checks
    /// were most of the cost of listing 10k notes.
    static func preview(_ text: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        var pendingSpace = false
        var scalars = 0
        for scalar in text.unicodeScalars {
            let isSpace = scalar.isASCII
                ? (scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" || scalar.value == 0x0B || scalar.value == 0x0C)
                : scalar.properties.isWhitespace
            if isSpace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(0x20); pendingSpace = false; scalars += 1 }
            out.append(contentsOf: UTF8.encode(scalar)!)
            scalars += 1
            if scalars >= 300 { break }   // enough for 200 characters of any realistic text
        }
        let s = String(decoding: out, as: UTF8.self)
        return scalars <= 200 ? s : String(s.prefix(200))
    }

    static func sameBytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    func requireNote(_ id: ULID, in db: Connection) throws -> Note {
        guard let note = try note(id, in: db) else { throw LibraryError.notFound(id) }
        return note
    }

    /// Runs a metadata-only change; logs it when `change` reports that something changed.
    private func changeMetadata(_ id: ULID, _ change: (Note, Connection) throws -> Bool) throws {
        try write { db in
            let note = try requireNote(id, in: db)
            if try change(note, db) { try log(.note, id, .upsert, bodyChanged: false, in: db) }
        }
    }

    private func insertTags(_ tagIDs: Set<ULID>, for noteID: ULID, in db: Connection) throws {
        let ins = try db.prepare("INSERT INTO note_tags (note_id, tag_id) VALUES (?, ?)")
        for tag in tagIDs { try ins.run([.id(noteID), .id(tag)]) }
    }

    private func deleteNote(_ id: ULID, in db: Connection) throws {
        try db.run("DELETE FROM notes WHERE id = ?", [.id(id)])
        try log(.note, id, .delete, bodyChanged: false, in: db)
    }
}

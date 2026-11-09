import Foundation

extension Library {
    static let notebookColumns = "id, name, parent_id, created, modified"

    static func notebook(_ s: Statement) -> Notebook {
        Notebook(id: s.ulid(0), name: s.text(1), parentID: s.optionalULID(2), created: s.int64(3), modified: s.int64(4))
    }

    public func createNotebook(name: String, parentID: ULID?) throws -> Notebook {
        try write { db in
            if let parentID { try requireNotebook(parentID, in: db) }
            let now = clock.now()
            let nb = Notebook(id: ULID.generate(at: now), name: name, parentID: parentID, created: now, modified: now)
            try db.run("INSERT INTO notebooks (\(Self.notebookColumns)) VALUES (?, ?, ?, ?, ?)",
                       [.id(nb.id), .text(name), .id(parentID), .int(now), .int(now)])
            try log(.notebook, nb.id, .upsert, bodyChanged: false, in: db)
            return nb
        }
    }

    public func renameNotebook(_ id: ULID, to name: String) throws {
        try write { db in
            try requireNotebook(id, in: db)
            try db.run("UPDATE notebooks SET name = ?, modified = ? WHERE id = ?", [.text(name), .int(clock.now()), .id(id)])
            try log(.notebook, id, .upsert, bodyChanged: false, in: db)
        }
    }

    public func moveNotebook(_ id: ULID, toParent parentID: ULID?) throws {
        try write { db in
            try requireNotebook(id, in: db)
            if let parentID {
                try requireNotebook(parentID, in: db)
                if try descendants(of: id, in: db).contains(parentID) { throw LibraryError.notebookCycle }
            }
            try db.run("UPDATE notebooks SET parent_id = ?, modified = ? WHERE id = ?", [.id(parentID), .int(clock.now()), .id(id)])
            try log(.notebook, id, .upsert, bodyChanged: false, in: db)
        }
    }

    /// Deletes the notebook and its sub-notebooks. Their notes go to Trash, at the root.
    public func deleteNotebook(_ id: ULID) throws {
        try write { db in
            try requireNotebook(id, in: db)
            let tree = try descendants(of: id, in: db)
            let now = clock.now()
            for nb in tree {
                let notes = try db.all("SELECT id, trashed_at FROM notes WHERE notebook_id = ?", [.id(nb)]) { ($0.ulid(0), $0.optionalInt64(1)) }
                for (noteID, trashedAt) in notes {
                    try db.run("UPDATE notes SET notebook_id = NULL, trashed_at = ? WHERE id = ?", [.int(trashedAt ?? now), .id(noteID)])
                    try log(.note, noteID, .upsert, bodyChanged: false, in: db)
                }
            }
            try db.run("DELETE FROM notebooks WHERE id = ?", [.id(id)])   // cascades to the subtree
            for nb in tree { try log(.notebook, nb, .delete, bodyChanged: false, in: db) }
        }
    }

    public func notebooks() throws -> [Notebook] {
        try db.all("SELECT \(Self.notebookColumns) FROM notebooks ORDER BY created, rowid", [], Self.notebook)
            .sorted { Library.nameOrder($0.name, $1.name) }   // stable sort: equal names keep creation order
    }

    public func descendants(of id: ULID) throws -> [ULID] {
        try descendants(of: id, in: db)
    }

    /// `id` and every notebook below it, parents before children.
    func descendants(of id: ULID, in db: Connection) throws -> [ULID] {
        try db.all("""
            WITH RECURSIVE tree(id, depth) AS (
              SELECT id, 0 FROM notebooks WHERE id = ?
              UNION ALL SELECT n.id, tree.depth + 1 FROM notebooks n JOIN tree ON n.parent_id = tree.id)
            SELECT id FROM tree ORDER BY depth
            """, [.id(id)]) { $0.ulid(0) }
    }

    func requireNotebook(_ id: ULID, in db: Connection) throws {
        let found = try db.all("SELECT 1 FROM notebooks WHERE id = ?", [.id(id)]) { _ in true }
        if found.isEmpty { throw LibraryError.notFound(id) }
    }
}

extension Library {
    /// Finder-like name order that ignores case, so names differing only in case stay in creation order.
    static func nameOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive], range: nil, locale: .current) == .orderedAscending
    }
}

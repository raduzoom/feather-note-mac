import Foundation

extension Library {
    static func tag(_ s: Statement) -> Tag {
        Tag(id: s.ulid(0), name: s.text(1), created: s.int64(2), modified: s.int64(3))
    }

    /// The key that makes tag names unique: Unicode-aware lowercase.
    static func tagKey(_ name: String) -> String { name.lowercased() }

    public func createTag(name: String) throws -> Tag {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidName }
        return try write { db in
            try requireFreeTagName(name, except: nil, in: db)
            let now = clock.now()
            let tag = Tag(id: ULID.generate(at: now), name: name, created: now, modified: now)
            try db.run("INSERT INTO tags (id, name, name_key, created, modified) VALUES (?, ?, ?, ?, ?)",
                       [.id(tag.id), .text(name), .text(Self.tagKey(name)), .int(now), .int(now)])
            try log(.tag, tag.id, .upsert, bodyChanged: false, in: db)
            return tag
        }
    }

    public func renameTag(_ id: ULID, to name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidName }
        try write { db in
            try requireTag(id, in: db)
            try requireFreeTagName(name, except: id, in: db)
            try db.run("UPDATE tags SET name = ?, name_key = ?, modified = ? WHERE id = ?",
                       [.text(name), .text(Self.tagKey(name)), .int(clock.now()), .id(id)])
            try log(.tag, id, .upsert, bodyChanged: false, in: db)
        }
    }

    /// Deletes the tag. Notes lose it without being logged (data-model.md "Trash").
    public func deleteTag(_ id: ULID) throws {
        try write { db in
            try requireTag(id, in: db)
            try db.run("DELETE FROM tags WHERE id = ?", [.id(id)])   // cascades to note_tags
            try log(.tag, id, .delete, bodyChanged: false, in: db)
        }
    }

    public func tags() throws -> [Tag] {
        try db.all("SELECT id, name, created, modified FROM tags", [], Self.tag)
            .sorted { Library.nameOrder($0.name, $1.name) }
    }

    public func tag(named name: String) throws -> Tag? {
        try db.all("SELECT id, name, created, modified FROM tags WHERE name_key = ?", [.text(Self.tagKey(name))], Self.tag).first
    }

    func requireTag(_ id: ULID, in db: Connection) throws {
        if try db.all("SELECT 1 FROM tags WHERE id = ?", [.id(id)], { _ in true }).isEmpty { throw LibraryError.notFound(id) }
    }

    private func requireFreeTagName(_ name: String, except id: ULID?, in db: Connection) throws {
        let key = Self.tagKey(name)
        let owners = try db.all("SELECT id FROM tags WHERE name_key = ?", [.text(key)]) { $0.ulid(0) }
        if owners.contains(where: { $0 != id }) { throw LibraryError.duplicateTagName(key) }
    }
}

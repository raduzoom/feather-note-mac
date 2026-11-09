/// Note counts for the sidebar. Trashed notes count only towards `trash`.
public struct LibraryCounts: Sendable, Equatable {
    public var all: Int
    public var pinned: Int
    public var trash: Int
    /// Per notebook, including its sub-notebooks (the same set `notes(in: .notebook)` returns).
    public var notebooks: [ULID: Int]

    public init(all: Int, pinned: Int, trash: Int, notebooks: [ULID: Int]) {
        self.all = all
        self.pinned = pinned
        self.trash = trash
        self.notebooks = notebooks
    }
}

extension Library {
    public func counts() throws -> LibraryCounts {
        let totals = try db.all("""
            SELECT count(*) FILTER (WHERE trashed_at IS NULL),
                   count(*) FILTER (WHERE trashed_at IS NULL AND pinned = 1),
                   count(*) FILTER (WHERE trashed_at IS NOT NULL)
            FROM notes
            """, []) { ($0.int64(0), $0.int64(1), $0.int64(2)) }[0]
        let direct = Dictionary(uniqueKeysWithValues: try db.all(
            "SELECT notebook_id, count(*) FROM notes WHERE trashed_at IS NULL AND notebook_id IS NOT NULL GROUP BY notebook_id", []
        ) { ($0.ulid(0), Int($0.int64(1))) })
        let parents = try db.all("SELECT id, parent_id FROM notebooks", []) { ($0.ulid(0), $0.optionalULID(1)) }
        let children = Dictionary(grouping: parents.compactMap { id, parent in parent.map { ($0, id) } }, by: \.0)
            .mapValues { $0.map(\.1) }

        var result: [ULID: Int] = [:]
        func total(_ id: ULID) -> Int {
            if let known = result[id] { return known }
            let sum = direct[id, default: 0] + (children[id] ?? []).reduce(0) { $0 + total($1) }
            result[id] = sum
            return sum
        }
        for (id, _) in parents { _ = total(id) }
        return LibraryCounts(all: Int(totals.0), pinned: Int(totals.1), trash: Int(totals.2), notebooks: result)
    }
}

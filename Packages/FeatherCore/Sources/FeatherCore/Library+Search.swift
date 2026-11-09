extension Library {
    /// Turns what a person typed into an FTS5 query: every word a quoted prefix term, all required.
    /// Words without a letter or digit are dropped; nil when nothing is left.
    static func ftsQuery(_ text: String) -> String? {
        // Control characters (NUL included) separate words: SQLite would read NUL as the end of the string.
        var cleaned = String.UnicodeScalarView()
        for u in text.unicodeScalars { cleaned.append(u.properties.generalCategory == .control ? " " : u) }
        let words = String(cleaned).split(whereSeparator: { $0.isWhitespace })
            .filter { $0.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil } }
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " ")
    }

    /// `inTrash`: search only notes in the Trash instead of only live ones.
    public func search(_ text: String, notebookID: ULID? = nil, tagIDs: Set<ULID> = [], inTrash: Bool = false, limit: Int = 200) throws -> [SearchHit] {
        guard let query = Self.ftsQuery(text) else { return [] }
        var sql = """
            SELECT n.id, n.title, substr(n.body, 1, 300), n.notebook_id, n.pinned, n.modified, n.trashed_at,
                   snippet(notes_fts, 1, char(2), char(3), '…', 12)
            FROM notes_fts JOIN notes n ON n.rowid = notes_fts.rowid
            WHERE notes_fts MATCH ? AND n.trashed_at \(inTrash ? "IS NOT NULL" : "IS NULL")
            """
        var values: [SQLValue] = [.text(query)]
        if let notebookID {
            let tree = try descendants(of: notebookID, in: db)
            guard !tree.isEmpty else { return [] }
            sql += " AND n.notebook_id IN (\(tree.map { _ in "?" }.joined(separator: ",")))"
            values += tree.map { .id($0) }
        }
        if !tagIDs.isEmpty {
            sql += " AND (SELECT count(*) FROM note_tags t WHERE t.note_id = n.id AND t.tag_id IN (\(tagIDs.map { _ in "?" }.joined(separator: ",")))) = ?"
            values += tagIDs.map { .id($0) } + [.int(Int64(tagIDs.count))]
        }
        sql += " ORDER BY bm25(notes_fts, 5.0, 1.0), n.id LIMIT ?"
        values.append(.int(Int64(limit)))
        return try db.all(sql, values) { s in
            let summary = Self.summary(s)
            let (snippet, matches) = Self.parseSnippet(s.text(7))
            return matches.isEmpty
                ? SearchHit(note: summary, snippet: summary.preview, matches: [])
                : SearchHit(note: summary, snippet: snippet, matches: matches)
        }
    }

    /// Removes the \u{2}…\u{3} markers FTS5 put around matches and returns their character ranges.
    static func parseSnippet(_ raw: String) -> (String, [Range<Int>]) {
        var out = ""
        var matches: [Range<Int>] = []
        var start: Int?
        var count = 0
        for ch in raw {
            switch ch {
            case "\u{2}": start = count
            case "\u{3}":
                if let s = start { matches.append(s..<count) }
                start = nil
            default:
                out.append(ch)
                count += 1
            }
        }
        return (out, matches)
    }
}

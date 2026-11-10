import Foundation

extension Library {
    /// Writes an importer's bundle in one transaction: notebooks (renamed " (2)"… on collision), tags by name
    /// (existing ones reused, case-insensitively), notes with their attachments. Cancelling the task, or any
    /// failure, imports nothing. The bundle's scratch folder is always removed.
    public func importBundle(_ b: ImportBundle, into parentID: ULID?,
                             progress: @Sendable (ImportProgress) -> Void = { _ in }) throws -> ImportReport {
        defer { if let scratch = b.scratch { try? FileManager.default.removeItem(at: scratch) } }
        return try write { db in
            if let parentID { try requireNotebook(parentID, in: db) }
            var report = ImportReport(notes: 0, notebooks: 0, attachments: 0, skipped: [])
            report.keptAsWritten = b.keptAsWritten

            // Notebooks, parents first; names unique among their siblings.
            let existing = try notebooks()
            var siblings: [ULID?: Set<String>] = [:]
            for nb in existing { siblings[nb.parentID, default: []].insert(nb.name.lowercased()) }
            var ids: [String: ULID] = [:]
            var pending = b.notebooks
            while !pending.isEmpty {
                let ready = pending.filter { $0.parentKey == nil || ids[$0.parentKey!] != nil }
                guard !ready.isEmpty else { break }   // a parent key that doesn't exist: those land at the top
                for nb in ready {
                    let parent = nb.parentKey.flatMap { ids[$0] } ?? parentID
                    let name = Self.uniqueName(nb.name, among: siblings[parent, default: []])
                    siblings[parent, default: []].insert(name.lowercased())
                    ids[nb.key] = try createNotebook(name: name, parentID: parent).id
                    report.notebooks += 1
                }
                pending.removeAll { p in ready.contains { $0.key == p.key } }
            }
            for nb in pending {   // orphans
                let name = Self.uniqueName(nb.name, among: siblings[parentID, default: []])
                siblings[parentID, default: []].insert(name.lowercased())
                ids[nb.key] = try createNotebook(name: name, parentID: parentID).id
                report.notebooks += 1
            }
            let tops = b.notebooks.filter { $0.parentKey == nil }
            report.topNotebookID = tops.count == 1 ? ids[tops[0].key] : nil

            // Tags by name.
            var tagIDs: [String: ULID] = [:]
            for tag in try tags() { tagIDs[Self.tagKey(tag.name)] = tag.id }

            for (n, note) in b.notes.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                var attachmentIDs: [String: ULID] = [:]   // by token
                for a in note.attachments {
                    let data = try Data(contentsOf: a.file)
                    attachmentIDs[a.token] = try addAttachment(data: data, filename: a.filename, mime: a.mime).id
                    report.attachments += 1
                }
                // whole tokens only: "r1" must not match the start of "r10"
                let body = Self.replaceTokens(in: note.body) { attachmentIDs[$0].map { "feather://attachment/\($0)" } }
                var noteTags: Set<ULID> = []
                for name in note.tags where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let key = Self.tagKey(name)
                    if let id = tagIDs[key] { noteTags.insert(id); continue }
                    let tag = try createTag(name: name)
                    tagIDs[key] = tag.id
                    noteTags.insert(tag.id)
                }
                let created = try createNote(title: note.title, body: body, notebookID: note.notebookKey.flatMap { ids[$0] } ?? parentID,
                                             tagIDs: noteTags, created: note.created, modified: note.modified ?? note.created)
                report.notes += 1
                for kind in Self.unique(note.preserved) {
                    report.preserved.append(PreservedContent(noteID: created.id, title: note.title, kind: kind))
                }
                progress(ImportProgress(notesDone: n + 1, notesTotal: b.notes.count, attachments: report.attachments, current: note.title))
            }
            if Task.isCancelled { throw CancellationError() }
            return report
        }
    }

    /// `name`, or `name (2)`, `name (3)`… — the first not in `taken` (lowercased).
    static func uniqueName(_ name: String, among taken: Set<String>) -> String {
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) (\(n))".lowercased()) { n += 1 }
        return "\(name) (\(n))"
    }

    static func unique(_ kinds: [PreservedContent.Kind]) -> [PreservedContent.Kind] {
        var seen: Set<PreservedContent.Kind> = []
        return kinds.filter { seen.insert($0).inserted }
    }
}

extension Library {
    static let tokenPattern = try! NSRegularExpression(pattern: "feather-import://([A-Za-z0-9_-]+)")

    /// Replaces each `feather-import://<token>` (the whole token) with `replacement(token)`; unknown tokens stay.
    static func replaceTokens(in body: String, _ replacement: (String) -> String?) -> String {
        let ns = body as NSString
        var out = ""
        var last = 0
        for m in tokenPattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += replacement(ns.substring(with: m.range(at: 1))) ?? ns.substring(with: m.range)
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }
}

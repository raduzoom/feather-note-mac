import Foundation

public struct ImportReport: Sendable, Equatable {
    public var notes: Int
    public var notebooks: Int
    public var attachments: Int
    public var skipped: [Skipped]

    public struct Skipped: Sendable, Equatable {
        public var path: String
        public var reason: Reason
    }

    public enum Reason: String, Sendable {
        case notUTF8
        case unreferencedFile
    }
}

extension Library {
    /// Imports a folder of Markdown files (data-model.md "Import from a Markdown folder").
    /// All of it runs in one transaction: a failure part-way imports nothing.
    public func importMarkdownFolder(from source: URL, into parentID: ULID? = nil) throws -> ImportReport {
        let fm = FileManager.default
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : url.lastPathComponent
        }

        return try write { db in
            if let parentID { try requireNotebook(parentID, in: db) }
            var report = ImportReport(notes: 0, notebooks: 0, attachments: 0, skipped: [])
            var attachmentIDs: [String: ULID] = [:]   // by resolved file path
            var otherFiles: [URL] = []

            func resolve(_ destination: String, from folder: URL) -> URL? {
                guard let first = destination.first, first != "#", first != "/" else { return nil }
                if destination.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return nil }
                if destination.contains("#") || destination.contains("?") { return nil }
                let decoded = destination.removingPercentEncoding ?? destination
                let target = folder.appending(path: decoded).standardizedFileURL.resolvingSymlinksInPath()
                guard target.path.hasPrefix(rootPrefix) else { return nil }
                // A link to another note stays a link; a .md file kept under _attachments is an attachment.
                let inAttachments = relative(target).split(separator: "/").dropLast().contains { $0.lowercased() == Self.attachmentsFolder }
                guard target.pathExtension.lowercased() != "md" || inAttachments else { return nil }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
                return target
            }

            func importNote(_ url: URL, notebook: ULID?) throws {
                var data = try Data(contentsOf: url)
                if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
                guard let text = String(data: data, encoding: .utf8) else {
                    report.skipped.append(.init(path: relative(url), reason: .notUTF8))
                    return
                }
                let parsed = FrontMatter.parse(text)
                var body = parsed.body
                for link in MarkdownLinks.destinations(in: body).reversed() {
                    guard let target = resolve(link.destination, from: url.deletingLastPathComponent()) else { continue }
                    let id: ULID
                    if let known = attachmentIDs[target.path] {
                        id = known
                    } else {
                        id = try addAttachment(contentsOf: target).id
                        attachmentIDs[target.path] = id
                    }
                    body.replaceSubrange(link.range, with: Self.attachmentURLPrefix + id.description)
                }

                let front = parsed.frontMatter
                let dates = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                func ms(_ d: Date?) -> Int64? { d.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) } }
                let created = front?.created ?? ms(dates?.creationDate) ?? clock.now()
                let modified = front?.modified ?? ms(dates?.contentModificationDate) ?? created

                var tagIDs: Set<ULID> = []
                for name in front?.tags ?? [] where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let existing = try tag(named: name) { tagIDs.insert(existing.id) } else { tagIDs.insert(try createTag(name: name).id) }
                }
                var id: ULID?
                if let wanted = front?.featherID, try !isItemID(wanted, in: db) { id = wanted }
                let note = try createNote(title: front?.title ?? url.deletingPathExtension().lastPathComponent, body: body,
                                          notebookID: notebook, tagIDs: tagIDs, id: id, created: created, modified: modified)
                if front?.pinned == true { try setPinned(note.id, true) }
                report.notes += 1
            }

            func walk(_ dir: URL, notebook: ULID?, inAttachments: Bool) throws {
                let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
                    .filter { !$0.lastPathComponent.hasPrefix(".") }
                    .sorted { Self.nameOrder($0.lastPathComponent, $1.lastPathComponent) }
                for entry in entries {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    if values.isDirectory == true {
                        if inAttachments || entry.lastPathComponent.lowercased() == Self.attachmentsFolder {
                            try walk(entry, notebook: notebook, inAttachments: true)
                        } else {
                            let nb = try createNotebook(name: entry.lastPathComponent, parentID: notebook)
                            report.notebooks += 1
                            try walk(entry, notebook: nb.id, inAttachments: false)
                        }
                    } else if values.isRegularFile == true {
                        if !inAttachments && entry.pathExtension.lowercased() == "md" {
                            try importNote(entry, notebook: notebook)
                        } else {
                            otherFiles.append(entry.standardizedFileURL.resolvingSymlinksInPath())
                        }
                    }
                }
            }

            try walk(root, notebook: parentID, inAttachments: false)
            for file in otherFiles where attachmentIDs[file.path] == nil {
                report.skipped.append(.init(path: relative(file), reason: .unreferencedFile))
            }
            report.attachments = attachmentIDs.count
            return report
        }
    }

    /// True if any item in the library already uses `id`.
    func isItemID(_ id: ULID, in db: Connection) throws -> Bool {
        let sql = """
            SELECT 1 FROM notes WHERE id = ?1 UNION ALL SELECT 1 FROM notebooks WHERE id = ?1
            UNION ALL SELECT 1 FROM tags WHERE id = ?1 UNION ALL SELECT 1 FROM attachments WHERE id = ?1
            """
        return try !db.all(sql, [.id(id)]) { _ in true }.isEmpty
    }
}

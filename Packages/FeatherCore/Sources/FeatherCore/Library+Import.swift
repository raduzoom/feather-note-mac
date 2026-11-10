import Foundation

public struct ImportReport: Sendable, Equatable {
    public var notes: Int
    public var notebooks: Int
    public var attachments: Int
    public var skipped: [Skipped]
    /// Notes holding content kept verbatim (tables, HTML, encrypted blocks, Notion blocks).
    public var preserved: [PreservedContent] = []
    /// Links between notes left as written (note links come in a point release).
    public var keptAsWritten = 0
    /// The single top notebook the import created, if there is one ("Show Imported Notes").
    public var topNotebookID: ULID?

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

            func attachmentID(for target: URL) throws -> ULID {
                if let known = attachmentIDs[target.path] { return known }
                let id = try addAttachment(contentsOf: target).id
                attachmentIDs[target.path] = id
                return id
            }

            /// Every non-Markdown file in the folder by lowercased name, with and without its extension.
            var fileIndex: [String: [URL]]?
            func filesNamed(_ name: String) -> [URL] {
                if fileIndex == nil {
                    var index: [String: [URL]] = [:]
                    let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    while let u = e?.nextObject() as? URL {
                        guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                              u.pathExtension.lowercased() != "md" else { continue }
                        let file = u.standardizedFileURL.resolvingSymlinksInPath()
                        index[file.lastPathComponent.lowercased(), default: []].append(file)
                        index[file.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(file)
                    }
                    fileIndex = index
                }
                return fileIndex?[name.lowercased()] ?? []
            }

            /// Obsidian/Bear: `![[file]]` embeds, reference definitions and `<img src>` to files in the folder.
            func rewriteVault(_ text: String, from folder: URL) throws -> String {
                var body = text
                for ref in MarkdownLinks.vaultReferences(in: body).reversed() {
                    switch ref {
                    case .wikiLink:
                        report.keptAsWritten += 1
                    case .embed(let range, let name, let alias):
                        let base = name.split(separator: "#").first.map(String.init) ?? name
                        let direct = resolve(base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? base, from: folder)
                        let candidates = direct.map { [$0] } ?? filesNamed((base as NSString).lastPathComponent)
                        // on a tie, the nearest path wins: most folders in common with the note, then the shortest
                        let target = candidates.min { a, b in
                            let ca = Self.commonPrefix(a.deletingLastPathComponent().path, folder.standardizedFileURL.resolvingSymlinksInPath().path)
                            let cb = Self.commonPrefix(b.deletingLastPathComponent().path, folder.standardizedFileURL.resolvingSymlinksInPath().path)
                            return ca != cb ? ca > cb : a.path.count < b.path.count
                        }
                        guard let target, target.pathExtension.lowercased() != "md" else { report.keptAsWritten += 1; continue }
                        let id = try attachmentID(for: target)
                        let label = (alias ?? name).replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                        let image = Self.mime(forFilename: target.lastPathComponent).hasPrefix("image/")
                        body.replaceSubrange(range, with: (image ? "!" : "") + "[\(label)](\(Self.attachmentURLPrefix)\(id))")
                    case .referenceDefinition(let range, let destination), .htmlImage(let range, let destination):
                        guard let target = resolve(destination, from: folder) else { continue }
                        body.replaceSubrange(range, with: Self.attachmentURLPrefix + (try attachmentID(for: target)).description)
                    }
                }
                return body
            }

            func importNote(_ url: URL, notebook: ULID?) throws {
                if Task.isCancelled { throw CancellationError() }   // Cancel Import rolls everything back
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
                body = try rewriteVault(body, from: url.deletingLastPathComponent())

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
            if Task.isCancelled { throw CancellationError() }
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

extension Library {
    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a.split(separator: "/"), b.split(separator: "/")).prefix { $0 == $1 }.count
    }
}

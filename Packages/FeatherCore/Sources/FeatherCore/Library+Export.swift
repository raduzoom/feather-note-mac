import Foundation

public struct ExportReport: Sendable, Equatable {
    public var notes: Int
    public var notebooks: Int
    public var attachments: Int
    public var root: URL
}

extension Library {
    static let attachmentsFolder = "_attachments"
    static let attachmentURLPrefix = "feather://attachment/"

    /// Writes the library (or one notebook and its sub-notebooks) as a Markdown folder inside `destination`.
    /// Never overwrites: the root folder gets ` (2)`, … if its name is taken.
    public func exportMarkdown(to destination: URL, notebookID: ULID? = nil) throws -> ExportReport {
        let fm = FileManager.default
        let all = try notebooks()
        let children = Dictionary(grouping: all, by: \.parentID)
        let tagNames = Dictionary(uniqueKeysWithValues: try tags().map { ($0.id, $0.name) })

        let rootName: String
        if let notebookID {
            guard let nb = all.first(where: { $0.id == notebookID }) else { throw LibraryError.notFound(notebookID) }
            rootName = FileNames.sanitize(nb.name)
        } else {
            rootName = "Feather Note Export"
        }
        var existing = Set(((try? fm.contentsOfDirectory(atPath: destination.path)) ?? []).map(FileNames.key))
        let root = destination.appending(path: FileNames.unique(rootName, ext: "", taken: &existing), directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var report = ExportReport(notes: 0, notebooks: 0, attachments: 0, root: root)

        func exportFolder(_ folder: URL, notebook: ULID?) throws {
            var taken: Set<String> = [FileNames.key(Self.attachmentsFolder)]
            for child in (children[notebook] ?? []) {
                let name = FileNames.unique(FileNames.sanitize(child.name), ext: "", taken: &taken)
                let url = folder.appending(path: name, directoryHint: .isDirectory)
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                report.notebooks += 1
                try exportFolder(url, notebook: child.id)
            }
            let ids = try db.all("SELECT id FROM notes WHERE trashed_at IS NULL AND notebook_id IS ? ORDER BY created, rowid",
                                 [.id(notebook)]) { $0.ulid(0) }
            for id in ids {
                guard let note = try note(id) else { continue }
                let file = FileNames.unique(FileNames.sanitize(note.title.isEmpty ? "Untitled" : note.title), ext: ".md", taken: &taken)
                let base = String(file.dropLast(3))
                let body = try exportAttachments(of: note.body, into: folder, noteBase: base, count: &report.attachments)
                let front = FrontMatter(featherID: note.id, title: note.title, created: note.created, modified: note.modified,
                                        tags: note.tagIDs.compactMap { tagNames[$0] }.sorted(by: Library.nameOrder),
                                        pinned: note.pinned)
                try Data((front.render() + body).utf8).write(to: folder.appending(path: file), options: .atomic)
                report.notes += 1
            }
        }

        if let notebookID {
            try exportFolder(root, notebook: notebookID)
        } else {
            try exportFolder(root, notebook: nil)
        }
        return report
    }

    /// Copies the attachments that `body` links to into `_attachments/<noteBase>/` and rewrites those link
    /// destinations to relative paths. Only link and image destinations outside code are rewritten, the same
    /// ones import turns back into attachments; `feather://` text anywhere else stays as written.
    private func exportAttachments(of body: String, into folder: URL, noteBase: String, count: inout Int) throws -> String {
        let links = MarkdownLinks.destinations(in: body).compactMap { link -> (Range<String.Index>, ULID)? in
            Self.attachmentID(inURL: link.destination).map { (link.range, $0) }
        }
        guard !links.isEmpty else { return body }
        let fm = FileManager.default
        var taken: Set<String> = []
        var paths: [ULID: String] = [:]
        var missing: Set<ULID> = []
        for (_, id) in links where paths[id] == nil && !missing.contains(id) {
            guard let a = try attachment(id) else { missing.insert(id); continue }
            let (stem, ext) = FileNames.splitExtension(FileNames.sanitize(a.filename))
            let name = FileNames.unique(stem, ext: ext, taken: &taken)
            let dir = folder.appending(path: Self.attachmentsFolder).appending(path: noteBase, directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: attachmentStore.url(for: a.sha256), to: dir.appending(path: name))
            count += 1
            paths[id] = [Self.attachmentsFolder, noteBase, name].map(Self.percentEncode).joined(separator: "/")
        }
        var out = body
        for (range, id) in links.reversed() {
            if let path = paths[id] { out.replaceSubrange(range, with: path) }
        }
        return out
    }

    /// The id in `feather://attachment/<id>` (prefix case-insensitive), or nil.
    static func attachmentID(inURL url: String) -> ULID? {
        guard url.count == attachmentURLPrefix.count + 26,
              url.lowercased().hasPrefix(attachmentURLPrefix) else { return nil }
        return ULID(string: String(url.suffix(26)))
    }

    static func percentEncode(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]()")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}

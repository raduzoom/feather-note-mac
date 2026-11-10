import FeatherCore
import Foundation
import UniformTypeIdentifiers

public enum NotionError: Error, Equatable {
    /// The zip holds no Notion pages.
    case notANotionExport
}

/// Reads a Notion "Markdown & CSV" export `.zip` into an `ImportBundle` (universal/specs/import-formats.md "Notion").
public struct NotionReader {
    public static func read(_ zip: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> ImportBundle {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "FeatherImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            try Unzip.extract(zip, into: scratch)
            var b = Builder(root: scratch)
            let top = b.addNotebook("Notion", parent: nil)
            try b.folder(scratch, notebook: top)
            guard !b.notes.isEmpty else { throw NotionError.notANotionExport }
            progress(1)
            return ImportBundle(notebooks: b.notebooks, notes: b.notes, scratch: scratch)
        } catch {
            try? fm.removeItem(at: scratch)
            throw error
        }
    }

    private struct Builder {
        let root: URL
        var notebooks: [ImportBundle.Notebook] = []
        var notes: [ImportBundle.Note] = []
        private var nextKey = 0
        private var tokens: [String: AttachmentFile] = [:]   // by resolved path

        init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

        mutating func addNotebook(_ name: String, parent: String?) -> String {
            nextKey += 1
            let key = "nb\(nextKey)"
            notebooks.append(.init(key: key, name: name, parentKey: parent))
            return key
        }

        /// Pages (`X <id>.md`), databases (`X <id>.csv`) and their sub-folders in `folder`, filed under `notebook`.
        mutating func folder(_ folder: URL, notebook: String) throws {
            let fm = FileManager.default
            // pages may start with "." (".NET notes"): skip only the system's own files, and every symlink, so
            // nothing outside the export can be read
            let items = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                .filter { url in
                    let name = url.lastPathComponent
                    guard name != "__MACOSX", name != ".DS_Store", !name.hasPrefix("._") else { return false }
                    return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let dirs = Set(items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent))
            var usedDirs: Set<String> = []

            // databases: prefer "X <id>_all.csv" over "X <id>.csv"
            var csvs: [String: URL] = [:]
            for url in items where url.pathExtension.lowercased() == "csv" {
                let stem = url.deletingPathExtension().lastPathComponent
                let base = stem.hasSuffix("_all") ? String(stem.dropLast(4)) : stem
                if csvs[base] == nil || stem.hasSuffix("_all") { csvs[base] = url }
            }
            let pageStems = items.filter { $0.pathExtension.lowercased() == "md" }.map { $0.deletingPathExtension().lastPathComponent }
            let owner = Self.folderOwners(stems: Set(pageStems).union(csvs.keys), dirs: dirs)
            for (stem, csv) in csvs.sorted(by: { $0.key < $1.key }) {
                let nb = addNotebook(NameRules.stripNotionID(stem).name, parent: notebook)
                let dir = owner[stem].flatMap { usedDirs.insert($0).inserted ? $0 : nil }
                try database(csv, rows: dir.map { folder.appending(path: $0) }, notebook: nb)
            }

            for url in items where url.pathExtension.lowercased() == "md" {
                let stem = url.deletingPathExtension().lastPathComponent
                if let dir = owner[stem], !usedDirs.contains(dir) {
                    // a page with sub-pages: a notebook holding the page and its children
                    let nb = addNotebook(title(of: url) ?? NameRules.stripNotionID(stem).name, parent: notebook)
                    notes.append(try page(url, notebook: nb).note)
                    usedDirs.insert(dir)
                    try self.folder(folder.appending(path: dir), notebook: nb)
                } else {
                    notes.append(try page(url, notebook: notebook).note)
                }
            }
            // folders without a page of their own (assets, or pages Notion exported without a parent file)
            for dir in dirs.subtracting(usedDirs).sorted() {
                let sub = folder.appending(path: dir)
                if containsPages(sub) { try self.folder(sub, notebook: notebook) }
            }
        }

        /// Which sub-folder belongs to each page or database stem: "X <id>/", or "X/" as current exports write
        /// it, when no other sibling is also named X once ids are removed.
        static func folderOwners(stems: Set<String>, dirs: Set<String>) -> [String: String] {
            var byName: [String: [String]] = [:]
            for stem in stems { byName[NameRules.stripNotionID(stem).name, default: []].append(stem) }
            var owners: [String: String] = [:]
            for stem in stems {
                if dirs.contains(stem) { owners[stem] = stem; continue }
                let (name, id) = NameRules.stripNotionID(stem)
                if id != nil, dirs.contains(name), byName[name]?.count == 1 { owners[stem] = name }
            }
            return owners
        }

        func containsPages(_ folder: URL) -> Bool {
            let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            while let url = e?.nextObject() as? URL {
                if ["md", "csv"].contains(url.pathExtension.lowercased()) { return true }
            }
            return false
        }

        func title(of page: URL) -> String? {
            guard let text = try? String(contentsOf: page, encoding: .utf8) else { return nil }
            return text.split(separator: "\n", omittingEmptySubsequences: false).first { $0.hasPrefix("# ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }

        /// A page as a note: the first "# " line is the title; attachments rewritten to tokens.
        /// `properties`: the row's CSV cells by header; its own "Header: value" lines are dropped only when the value
        /// is that cell (the CSV is where properties come from).
        mutating func page(_ url: URL, notebook: String, properties: [String: String] = [:]) throws -> (note: ImportBundle.Note, title: String) {
            var data = try Data(contentsOf: url)
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            var lines = text.components(separatedBy: "\n")
            var title = NameRules.stripNotionID(url.deletingPathExtension().lastPathComponent).name
            if let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[i].hasPrefix("# ") {
                title = String(lines[i].dropFirst(2)).trimmingCharacters(in: .whitespaces)
                lines.removeSubrange(0...i)
            }
            if !properties.isEmpty {
                // a database row page repeats its properties as "Key: value" lines; they come from the CSV instead
                var i = 0
                while i < lines.count {
                    let line = lines[i]
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
                    guard let colon = line.range(of: ": "),
                          let cell = properties[String(line[..<colon.lowerBound])],
                          !cell.isEmpty,
                          String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces) == cell.replacingOccurrences(of: "\n", with: " ")
                    else { break }
                    i += 1
                }
                lines.removeSubrange(0..<i)
            }
            var attachments: [AttachmentFile] = []
            let body = rewriteLinks(lines.joined(separator: "\n"), from: url.deletingLastPathComponent(), attachments: &attachments)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preserved: [PreservedContent.Kind] = body.contains("<aside") || body.contains("<details") ? [.notionBlock] : []
            return (ImportBundle.Note(title: title, body: body, notebookKey: notebook, attachments: attachments, preserved: preserved), title)
        }

        /// One note per row; columns become tags or a property list (import-formats.md, Decision 8).
        mutating func database(_ csv: URL, rows folder: URL?, notebook: String) throws {
            let table = try CSVTable(String(decoding: try Data(contentsOf: csv), as: UTF8.self))
            guard !table.header.isEmpty else { return }
            let tagColumns = Set((1..<max(1, table.header.count)).filter { Self.isTagColumn(table, $0) })
            // row pages by title
            var pages: [String: [URL]] = [:]
            if let folder {
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension.lowercased() == "md" {
                    pages[title(of: url) ?? NameRules.stripNotionID(url.deletingPathExtension().lastPathComponent).name, default: []].append(url)
                }
            }
            for row in table.rows {
                let name = row.first ?? ""
                var tags: [String] = []
                var props: [String] = []
                for (c, header) in table.header.enumerated().dropFirst() {
                    let value = c < row.count ? row[c].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    guard !value.isEmpty else { continue }
                    if tagColumns.contains(c) {
                        tags += value.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    } else {
                        props.append("- **\(header):** \(value.replacingOccurrences(of: "\n", with: " "))")
                    }
                }
                var note: ImportBundle.Note
                if var list = pages[name], !list.isEmpty {
                    let url = list.removeFirst()
                    pages[name] = list
                    var cells: [String: String] = [:]
                    for (c, header) in table.header.enumerated() where c < row.count { cells[header] = row[c].trimmingCharacters(in: .whitespacesAndNewlines) }
                    note = try page(url, notebook: notebook, properties: cells).note
                    let stem = url.deletingPathExtension().lastPathComponent
                    for dir in Set([stem, NameRules.stripNotionID(stem).name]).sorted() {
                        let sub = url.deletingLastPathComponent().appending(path: dir)
                        if FileManager.default.fileExists(atPath: sub.path), containsPages(sub) { try self.folder(sub, notebook: notebook); break }
                    }
                } else {
                    note = ImportBundle.Note(title: name, body: "", notebookKey: notebook)
                }
                note.tags = Self.unique(tags)
                let list = props.joined(separator: "\n")
                note.body = [list, note.body].filter { !$0.isEmpty }.joined(separator: "\n\n")
                notes.append(note)
            }
            // pages with no row in the CSV are still notes
            for url in pages.values.flatMap({ $0 }) { notes.append(try page(url, notebook: notebook).note) }
        }

        static func unique(_ a: [String]) -> [String] {
            var seen: Set<String> = []
            return a.filter { seen.insert($0.lowercased()).inserted }
        }

        /// Decision 8: header "Tags", or short repeated values that aren't numbers, dates or URLs.
        static func isTagColumn(_ t: CSVTable, _ c: Int) -> Bool {
            if t.header[c].lowercased() == "tags" { return true }
            var counts: [String: Int] = [:]
            var any = false
            for row in t.rows {
                guard c < row.count else { continue }
                let value = row[c].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                any = true
                for piece in value.components(separatedBy: ", ") {
                    let p = piece.trimmingCharacters(in: .whitespaces)
                    if p.count > 30 || p.contains("://") || p.contains("\n") || Double(p) != nil || isDate(p) { return false }
                    counts[p, default: 0] += 1
                }
            }
            return any && counts.values.contains { $0 > 1 }
        }

        static func isDate(_ s: String) -> Bool {
            s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
                || s.range(of: #"^[A-Z][a-z]+ \d{1,2}, \d{4}"#, options: .regularExpression) != nil
                || s.range(of: #"^\d{1,2}/\d{1,2}/\d{2,4}"#, options: .regularExpression) != nil
        }

        /// Links and images to files inside the export become attachment tokens; links to pages, URLs and
        /// anything inside code stay as written.
        mutating func rewriteLinks(_ text: String, from folder: URL, attachments: inout [AttachmentFile]) -> String {
            // alt text may hold bracket pairs ("shot [1].png" is how Notion writes a file name)
            let regex = try! NSRegularExpression(pattern: #"(!?\[(?:[^\[\]\n]|\[[^\[\]\n]*\])*\]\()([^)\s]+)(\))|(<img\b[^>]*?\bsrc=")([^"]+)(")"#)
            var out: [String] = []
            var fence: String?
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let f = fence {
                    if trimmed.hasPrefix(f) { fence = nil }
                    out.append(line); continue
                }
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    fence = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
                    out.append(line); continue
                }
                let ns = line as NSString
                var result = ""
                var last = 0
                for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let isImg = m.range(at: 5).location != NSNotFound
                    let destRange = isImg ? m.range(at: 5) : m.range(at: 2)
                    // skip anything inside an inline code span (an odd number of backticks before it)
                    let before = ns.substring(to: m.range.location)
                    if before.filter({ $0 == "`" }).count % 2 == 1 { continue }
                    result += ns.substring(with: NSRange(location: last, length: destRange.location - last))
                    let dest = ns.substring(with: destRange)
                    if let token = attachmentToken(dest, from: folder, attachments: &attachments) {
                        result += ImportBundle.tokenScheme + token
                    } else {
                        result += dest
                    }
                    last = NSMaxRange(destRange)
                }
                result += ns.substring(from: last)
                out.append(result)
            }
            return out.joined(separator: "\n")
        }

        mutating func attachmentToken(_ dest: String, from folder: URL, attachments: inout [AttachmentFile]) -> String? {
            guard let first = dest.first, first != "#", first != "/",
                  dest.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else { return nil }
            let decoded = dest.removingPercentEncoding ?? dest
            let target = folder.appending(path: decoded).standardizedFileURL.resolvingSymlinksInPath()
            guard target.path.hasPrefix(root.path + "/"), target.pathExtension.lowercased() != "md" else { return nil }
            // a database (its CSV carries a Notion id) is linked like a page
            if target.pathExtension.lowercased() == "csv" {
                let stem = target.deletingPathExtension().lastPathComponent
                if NameRules.stripNotionID(stem.hasSuffix("_all") ? String(stem.dropLast(4)) : stem).id != nil { return nil }
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            if let a = tokens[target.path] {
                if !attachments.contains(a) { attachments.append(a) }
                return a.token
            }
            let a = AttachmentFile(token: "n\(tokens.count + 1)", file: target, filename: target.lastPathComponent,
                                   mime: UTType(filenameExtension: target.pathExtension)?.preferredMIMEType)
            tokens[target.path] = a
            attachments.append(a)
            return a.token
        }
    }
}

import CryptoKit
import FeatherCore
import Foundation
import UniformTypeIdentifiers

public enum ENEXError: Error, Equatable {
    /// The file isn't an Evernote export.
    case notENEX
    /// The XML breaks off or is broken at this line.
    case malformed(line: Int)
}

/// Reads an Evernote `.enex` export into an `ImportBundle` (universal/specs/import-formats.md "Evernote").
/// Streams the XML: each resource is base64-decoded in chunks straight to a file in the bundle's scratch folder,
/// so a large export never sits in memory. Never resolves the DTD (no network).
public struct ENEXReader {
    /// `scratchIn`: where the scratch folder goes (the temporary folder by default; tests pass their own).
    public static func read(_ url: URL, scratchIn: URL? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> ImportBundle {
        let fm = FileManager.default
        let scratch = (scratchIn ?? fm.temporaryDirectory).appending(path: "FeatherImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            let extracted = try ResourceExtractor(enex: url, scratch: scratch)
            defer { try? fm.removeItem(at: extracted.skeleton) }
            let total = max(1, countNotes(in: extracted.skeleton))
            guard let stream = InputStream(url: extracted.skeleton) else { throw ENEXError.notENEX }
            let parser = XMLParser(stream: stream)
            parser.shouldResolveExternalEntities = false
            let handler = Handler(resources: extracted.resources, total: total, progress: progress)
            parser.delegate = handler
            let ok = parser.parse()
            if let error = handler.error { throw error }
            guard handler.sawRoot else { throw ENEXError.notENEX }
            guard ok, handler.finished else { throw ENEXError.malformed(line: parser.lineNumber) }
            // ENML is converted after the ENEX parse: NSXMLParser can't run inside another parser's callback
            let notes = handler.raw.map { r -> ImportBundle.Note in
                var body = convert(r.enml, resources: r.resources)
                if let source = r.sourceURL, !source.isEmpty {
                    body.markdown += (body.markdown.isEmpty ? "" : "\n\n") + "Source: \(source)"
                }
                var note = r.note
                note.body = body.markdown
                note.preserved = body.preserved
                return note
            }
            let name = url.deletingPathExtension().lastPathComponent
            return ImportBundle(notebooks: [.init(key: "enex", name: name, parentKey: nil)], notes: notes, scratch: scratch)
        } catch {
            try? fm.removeItem(at: scratch)
            throw error
        }
    }

    /// Counts `<note>` tags with a chunked byte scan, for progress.
    static func countNotes(in url: URL) -> Int {
        guard let h = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? h.close() }
        let needle = Array("<note>".utf8)
        var count = 0
        var carry: [UInt8] = []
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
            let bytes = carry + chunk
            var i = 0
            while i + needle.count <= bytes.count {
                if bytes[i] == 0x3C, Array(bytes[i..<i + needle.count]) == needle { count += 1; i += needle.count } else { i += 1 }
            }
            carry = Array(bytes.suffix(needle.count - 1))
        }
        return count
    }

    static func date(_ s: String) -> Int64? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines)).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    private final class Handler: NSObject, XMLParserDelegate {
        let extracted: [String: ResourceExtractor.Resource]
        let total: Int
        let progress: @Sendable (Double) -> Void
        /// Notes as read: the ENML, its resources and source URL, converted after parsing.
        var raw: [(note: ImportBundle.Note, enml: String, resources: [(file: AttachmentFile, md5: String)], sourceURL: String?)] = []
        var error: ENEXError?
        var sawRoot = false
        var finished = false

        private var path: [String] = []
        private var text = ""
        // the note being read
        private var title = "", content = "", created: Int64?, modified: Int64?, tags: [String] = [], sourceURL: String?
        private var resources: [(file: AttachmentFile, md5: String)] = []
        // the resource being read (its data was extracted to a file by ResourceExtractor; `data` holds the token)
        private var token: String?
        private var mime: String?, fileName: String?

        init(resources: [String: ResourceExtractor.Resource], total: Int, progress: @escaping @Sendable (Double) -> Void) {
            self.extracted = resources
            self.total = total
            self.progress = progress
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if path.isEmpty {
                guard name == "en-export" else { error = .notENEX; parser.abortParsing(); return }
                sawRoot = true
            }
            path.append(name)
            text = ""
            switch name {
            case "note":
                title = ""; content = ""; created = nil; modified = nil; tags = []; sourceURL = nil; resources = []
            case "resource":
                mime = nil; fileName = nil; token = nil
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            text += String(decoding: block, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let parent = path.dropLast().last
            switch (name, parent) {
            case ("title", "note"): title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case ("content", "note"): content = text
            case ("created", "note"): created = ENEXReader.date(text)
            case ("updated", "note"): modified = ENEXReader.date(text)
            case ("tag", "note"):
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { tags.append(t) }
            case ("source-url", "note-attributes"): sourceURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case ("mime", "resource"): mime = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case ("file-name", "resource-attributes"): fileName = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case ("data", "resource"):
                token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case ("resource", _):
                guard let token, let r = extracted[token] else { break }
                let ext = mime.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "bin"
                let name = (fileName?.isEmpty == false ? fileName! : "attachment.\(ext)")
                resources.append((AttachmentFile(token: token, file: r.file, filename: name, mime: mime), r.md5))
            case ("note", _):
                finishNote()
            case ("en-export", _):
                finished = true
            default:
                break
            }
            path.removeLast()
            text = ""
        }

        private func finishNote() {
            let note = ImportBundle.Note(title: title, body: "", notebookKey: "enex", tags: tags, created: created,
                                         modified: modified ?? created, attachments: resources.map(\.file))
            raw.append((note, content, resources, sourceURL))
            progress(Double(raw.count) / Double(total))
        }
    }
}

extension ENEXReader {
    /// The note's ENML as Markdown; resources the ENML never shows are appended as links, so none is dropped.
    static func convert(_ enml: String, resources: [(file: AttachmentFile, md5: String)]) -> (markdown: String, preserved: [PreservedContent.Kind]) {
        var byHash: [String: AttachmentFile] = [:]
        for r in resources { byHash[r.md5] = r.file }
        let r = ENMLConverter.convert(enml, resources: byHash)
        let unreferenced = resources.map(\.file).filter { !r.attachments.contains($0) }
        let links = unreferenced.map { a -> String in
            let link = "[\(a.filename.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]"))](\(ImportBundle.tokenScheme)\(a.token))"
            return (a.mime ?? "").hasPrefix("image/") ? "!" + link : link
        }
        let markdown = ([r.markdown] + (links.isEmpty ? [] : [links.joined(separator: "\n")])).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (markdown, r.preserved)
    }
}

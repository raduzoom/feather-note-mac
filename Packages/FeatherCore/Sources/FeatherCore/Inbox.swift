import Foundation

/// Something captured from outside the editor (quick note, Services, Share extension), waiting to become a note.
public struct InboxItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case text, url, files }

    /// Also the id of the note it becomes, so capturing the same item twice creates one note.
    public var id: ULID
    public var kind: Kind
    public var text: String?
    public var url: String?
    public var title: String?
    /// Paths of the item's files, relative to its inbox folder.
    public var files: [String]
    public var created: Int64

    public init(id: ULID, kind: Kind, text: String? = nil, url: String? = nil, title: String? = nil, files: [String] = [], created: Int64) {
        self.id = id
        self.kind = kind
        self.text = text
        self.url = url
        self.title = title
        self.files = files
        self.created = created
    }
}

extension ULID: Codable {
    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = ULID(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a ULID: \(s)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// A folder of pending captures: `<directory>/<item id>/item.json` plus the item's files.
/// A folder is removed only after its note is committed.
public struct Inbox: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Stores `item` with copies of `files` (their names go into `item.files`). The JSON is written last,
    /// so a half-written folder is never picked up.
    public func write(_ item: InboxItem, files: [URL]) throws {
        let fm = FileManager.default
        let folder = directory.appending(path: item.id.description, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var item = item
        item.files = []
        // files/<n>/<name>: two files with the same name (or one named item.json) stay separate
        for (n, file) in files.enumerated() {
            let relative = "files/\(n)/\(file.lastPathComponent)"
            let target = folder.appending(path: relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: file, to: target)
            item.files.append(relative)
        }
        try JSONEncoder().encode(item).write(to: folder.appending(path: "item.json"), options: .atomic)
    }

    /// Readable items, oldest first. Folders whose JSON doesn't decode are skipped and left alone.
    public func pending() throws -> [(item: InboxItem, folder: URL)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let folders = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let items = folders.compactMap { folder -> (InboxItem, URL)? in
            guard let data = try? Data(contentsOf: folder.appending(path: "item.json")),
                  let item = try? JSONDecoder().decode(InboxItem.self, from: data) else { return nil }
            return (item, folder)
        }
        return items.sorted { ($0.0.created, $0.0.id) < ($1.0.created, $1.0.id) }.map { (item: $0.0, folder: $0.1) }
    }

    public func remove(_ id: ULID) throws {
        let folder = directory.appending(path: id.description, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}

/// How captured text becomes a title and a body.
public enum CaptureText {
    static let maxTitle = 100

    /// The first non-empty line, trimmed and cut at a word boundary at 100 characters, is the title; the rest of
    /// that line (when it was cut) and the lines after it are the body. No text is dropped.
    public static func split(_ text: String) -> (title: String, body: String) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return ("", "") }
        let line = lines[first].trimmingCharacters(in: .whitespaces)
        var title = line
        var remainder = ""
        if line.count > maxTitle {
            let cut = line.prefix(maxTitle)
            let end = cut.lastIndex(of: " ") ?? cut.endIndex
            title = String(line[..<end]).trimmingCharacters(in: .whitespaces)
            remainder = String(line[end...]).trimmingCharacters(in: .whitespaces)
        }
        let rest = lines[(first + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        let body = [remainder, rest].filter { !$0.isEmpty }.joined(separator: "\n")
        return (title, body)
    }
}

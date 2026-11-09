import Foundation

/// The YAML front matter Feather Note writes at the top of an exported note (data-model.md "Front matter").
struct FrontMatter: Equatable {
    init(featherID: ULID? = nil, title: String? = nil, created: Int64? = nil, modified: Int64? = nil, tags: [String]? = nil, pinned: Bool? = nil) {
        self.featherID = featherID; self.title = title; self.created = created; self.modified = modified; self.tags = tags; self.pinned = pinned
    }

    var featherID: ULID?
    var title: String?
    var created: Int64?
    var modified: Int64?
    var tags: [String]?
    var pinned: Bool?

    func render() -> String {
        var lines = ["---"]
        if let featherID { lines.append("feather_id: \(featherID)") }
        if let title { lines.append("title: \(Self.scalar(title))") }
        if let created { lines.append("created: \(Self.timestamp(created))") }
        if let modified { lines.append("modified: \(Self.timestamp(modified))") }
        if let tags { lines.append("tags: [\(tags.map(Self.tagItem).joined(separator: ", "))]") }
        if let pinned { lines.append("pinned: \(pinned)") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: Scalars

    private static let indicators: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
    private static let keywords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]

    static func needsQuotes(_ s: String) -> Bool {
        guard let first = s.first, let last = s.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if indicators.contains(first) { return true }
        if s.contains(": ") || s.contains(" #") || last == ":" { return true }
        if keywords.contains(s.lowercased()) { return true }
        if Double(s) != nil { return true }
        if s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return true }
        return false
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.properties.generalCategory == .control {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func scalar(_ s: String) -> String { needsQuotes(s) ? quoted(s) : s }

    static func tagItem(_ s: String) -> String {
        needsQuotes(s) || s.contains(where: { ",[]{}'\"".contains($0) }) ? quoted(s) : s
    }

    // MARK: Timestamps

    static func timestamp(_ ms: Int64) -> String {
        let seconds = Int(ms.quotientAndRemainder(dividingBy: 1000).quotient - (ms < 0 && ms % 1000 != 0 ? 1 : 0))
        let millis = Int(((ms % 1000) + 1000) % 1000)
        var t = time_t(seconds)
        var parts = tm()
        gmtime_r(&t, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec, millis)
    }
}

// MARK: - Reading

extension FrontMatter {
    static let knownKeys: Set<String> = ["feather_id", "title", "created", "modified", "tags", "pinned"]

    /// Splits a leading YAML front matter block off `text`.
    /// `keepBlock` is true when the block has anything this reader does not understand; the caller then
    /// leaves the block in the body as written (`body` is the whole text) but still uses the known keys.
    static func parse(_ text: String) -> (frontMatter: FrontMatter?, body: String, keepBlock: Bool) {
        let none: (FrontMatter?, String, Bool) = (nil, text, false)
        let lines = splitLines(text)
        guard let first = lines.first, first.content == "---", first.hasNewline else { return none }
        guard let closeIndex = lines.dropFirst().firstIndex(where: { $0.content == "---" }) else { return none }

        let inner = lines[1..<closeIndex].map(\.content)
        guard inner.contains(where: { !$0.allSatisfy(\.isWhitespace) }) else { return none }   // `---` `---` is two rules, not a block
        var bodyStart = lines[closeIndex].end
        if closeIndex + 1 < lines.count, lines[closeIndex + 1].content.isEmpty, lines[closeIndex + 1].hasNewline {
            bodyStart = lines[closeIndex + 1].end   // the blank line export writes after the block
        }
        let (fm, clean) = read(inner)
        return clean ? (fm, String(text[bodyStart...]), false) : (fm, text, true)
    }

    private struct Line {
        var content: Substring
        var end: String.Index   // just past the newline
        var hasNewline: Bool
    }

    private static func splitLines(_ text: String) -> [Line] {
        var out: [Line] = []
        var start = text.startIndex
        let utf8 = text.utf8
        while start < text.endIndex {
            if let nl = utf8[start...].firstIndex(of: UInt8(ascii: "\n")) {
                var content = text[start..<nl]
                if content.utf8.last == UInt8(ascii: "\r") { content = text[start..<utf8.index(before: nl)] }
                let end = utf8.index(after: nl)
                out.append(Line(content: content, end: end, hasNewline: true))
                start = end
            } else {
                out.append(Line(content: text[start...], end: text.endIndex, hasNewline: false))
                start = text.endIndex
            }
        }
        return out
    }

    /// Reads the known keys. `clean` is false if any line is unknown or does not parse.
    private static func read(_ lines: [Substring]) -> (FrontMatter, Bool) {
        var fm = FrontMatter()
        var clean = true
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { clean = false; continue }
            let key = String(line[..<colon])
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "feather_id":
                if let v = scalarValue(raw), let id = ULID(string: v) { fm.featherID = id } else { clean = false }
            case "title":
                if let v = scalarValue(raw) { fm.title = v } else { clean = false }
            case "created", "modified":
                if let v = scalarValue(raw), let ms = parseTimestamp(v) {
                    if key == "created" { fm.created = ms } else { fm.modified = ms }
                } else { clean = false }
            case "pinned":
                switch raw { case "true": fm.pinned = true; case "false": fm.pinned = false; default: clean = false }
            case "tags":
                if raw.isEmpty {
                    var items: [String] = []
                    while i < lines.count {
                        let item = lines[i].drop(while: { $0 == " " })
                        guard item.hasPrefix("- ") || item == "-" else { break }
                        i += 1
                        if let v = scalarValue(item.dropFirst().trimmingCharacters(in: .whitespaces)) { items.append(v) } else { clean = false }
                    }
                    fm.tags = items
                } else if let items = flowList(raw) {
                    fm.tags = items
                } else {
                    clean = false
                }
            default:
                clean = false
            }
        }
        return (fm, clean)
    }

    /// A plain, double-quoted or single-quoted YAML scalar. Nil if malformed.
    static func scalarValue(_ raw: String) -> String? {
        guard let first = raw.first else { return "" }
        if first == "\"" {
            var out = ""
            var scalars = raw.unicodeScalars.dropFirst().makeIterator()
            while let c = scalars.next() {
                switch c {
                case "\"":
                    return scalars.next() == nil ? out : nil
                case "\\":
                    guard let e = scalars.next() else { return nil }
                    switch e {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "r": out += "\r"
                    case "\"": out += "\""
                    case "\\": out += "\\"
                    case "/": out += "/"
                    case "0": out += "\0"
                    case "u", "x", "U":
                        let n = e == "u" ? 4 : e == "x" ? 2 : 8
                        var hex = ""
                        for _ in 0..<n { guard let h = scalars.next() else { return nil }; hex.unicodeScalars.append(h) }
                        guard let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else { return nil }
                        out.unicodeScalars.append(u)
                    default: return nil
                    }
                default:
                    out.unicodeScalars.append(c)
                }
            }
            return nil
        }
        if first == "'" {
            guard raw.count >= 2, raw.last == "'" else { return nil }
            let inner = raw.dropFirst().dropLast()
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    /// `[a, "b, c", 'd']`. Nil if malformed.
    static func flowList(_ raw: String) -> [String]? {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return nil }
        let inner = raw.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for c in inner {
            if let q = quote {
                current.append(c)
                if escaped { escaped = false } else if c == "\\" && q == "\"" { escaped = true } else if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"", "'" where current.allSatisfy(\.isWhitespace):   // a quote opens only at the start of an item
                quote = c; current.append(c)
            case ",": items.append(current); current = ""
            default: current.append(c)
            }
        }
        guard quote == nil else { return nil }
        items.append(current)
        let trimmed = items.map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed == [""] { return [] }
        var out: [String] = []
        for t in trimmed {
            guard !t.isEmpty, let v = scalarValue(t) else { return nil }
            out.append(v)
        }
        return out
    }

    /// RFC 3339 (with or without fractional seconds) or a plain date, as ms since the epoch.
    static func parseTimestamp(_ s: String) -> Int64? {
        let f = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            f.formatOptions = options
            if let d = f.date(from: s) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        }
        return nil
    }
}

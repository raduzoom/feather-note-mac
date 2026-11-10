/// Finds inline link and image destinations in Markdown, skipping code.
/// A scanner for the cases import needs, not a CommonMark parser.
enum MarkdownLinks {
    static func destinations(in body: String) -> [(range: Range<String.Index>, destination: String)] {
        proseLines(body).flatMap(inlineDestinations(in:))
    }

    /// Obsidian and Bear constructs outside code (Phase 5, import-formats.md "Markdown folder").
    enum VaultReference {
        /// `![[name]]` or `![[name|alias]]`; `range` covers the whole embed.
        case embed(range: Range<String.Index>, name: String, alias: String?)
        /// `[[note]]`: kept as written.
        case wikiLink(range: Range<String.Index>)
        /// `[ref]: destination`; `range` covers the destination.
        case referenceDefinition(range: Range<String.Index>, destination: String)
        /// `<img src="…">`; `range` covers the src value.
        case htmlImage(range: Range<String.Index>, source: String)
    }

    static func vaultReferences(in body: String) -> [VaultReference] {
        var out: [VaultReference] = []
        for line in proseLines(body) {
            let content = line.drop(while: { $0 == " " })
            if line.distance(from: line.startIndex, to: content.startIndex) <= 3, content.first == "[",
               let close = content.firstIndex(of: "]"), content.index(after: close) < content.endIndex,
               content[content.index(after: close)] == ":" {
                var i = content.index(close, offsetBy: 2)
                while i < content.endIndex, content[i] == " " || content[i] == "\t" { i = content.index(after: i) }
                if i < content.endIndex {
                    var end = i
                    if content[i] == "<", let gt = content[i...].firstIndex(of: ">") {
                        i = content.index(after: i); end = gt
                    } else {
                        while end < content.endIndex, !content[end].isWhitespace { end = content.index(after: end) }
                    }
                    if i < end { out.append(.referenceDefinition(range: i..<end, destination: String(content[i..<end]))) }
                }
                continue
            }
            out += inlineVaultReferences(in: line)
        }
        return out
    }

    private static func inlineVaultReferences(in line: Substring) -> [VaultReference] {
        var out: [VaultReference] = []
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\\" {
                i = line.index(after: i)
                if i < line.endIndex { i = line.index(after: i) }
                continue
            }
            if c == "`" {
                let n = run(of: "`", in: line[i...])
                let afterOpen = line.index(i, offsetBy: n)
                i = closingBackticks(n, in: line[afterOpen...]) ?? afterOpen
                continue
            }
            let rest = line[i...]
            if rest.hasPrefix("![["), let close = rest.range(of: "]]") {
                let inner = rest[rest.index(i, offsetBy: 3)..<close.lowerBound]
                let parts = inner.split(separator: "|", maxSplits: 1).map { String($0) }
                if let name = parts.first, !name.isEmpty {
                    out.append(.embed(range: i..<close.upperBound, name: name, alias: parts.count > 1 ? parts[1] : nil))
                }
                i = close.upperBound
                continue
            }
            if rest.hasPrefix("[["), let close = rest.range(of: "]]") {
                out.append(.wikiLink(range: i..<close.upperBound))
                i = close.upperBound
                continue
            }
            if rest.lowercased().hasPrefix("<img"), let end = rest.firstIndex(of: ">") {
                let tag = rest[i..<end]
                if let src = tag.range(of: #"\bsrc\s*=\s*"([^"]*)""#, options: [.regularExpression, .caseInsensitive]),
                   let q1 = tag[src].firstIndex(of: "\"") {
                    let valueStart = tag.index(after: q1)
                    let valueEnd = tag.index(before: src.upperBound)
                    out.append(.htmlImage(range: valueStart..<valueEnd, source: String(tag[valueStart..<valueEnd])))
                }
                i = end
                continue
            }
            i = line.index(after: i)
        }
        return out
    }

    /// The lines of `body` that are prose: not in fenced or indented code.
    private static func proseLines(_ body: String) -> [Substring] {
        var out: [Substring] = []
        var fence: (char: Character, count: Int)?
        var previousBlank = true
        var inIndentedCode = false
        var inList = false

        // Split on the "\n" scalar: as Characters, "\r\n" is one grapheme and never equals "\n".
        for scalarLine in body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = Substring(scalarLine)
            let line = rawLine.unicodeScalars.last == "\r" ? Substring(rawLine.unicodeScalars.dropLast()) : rawLine
            let indent = leadingIndent(line)
            let content = line.drop(while: { $0 == " " || $0 == "\t" })

            if let open = fence {
                if indent < 4, run(of: open.char, in: content) >= open.count,
                   content.drop(while: { $0 == open.char }).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                continue
            }
            if indent < 4, let c = content.first, c == "`" || c == "~", run(of: c, in: content) >= 3 {
                fence = (c, run(of: c, in: content))
                previousBlank = false
                continue
            }
            if content.isEmpty {
                previousBlank = true
                continue
            }
            if indent >= 4 && (previousBlank || inIndentedCode) && !inList {
                inIndentedCode = true
                previousBlank = false
                continue
            }
            inIndentedCode = false
            previousBlank = false
            if isListItem(content) { inList = true } else if indent == 0 { inList = false }
            out.append(line)
        }
        return out
    }

    private static func leadingIndent(_ line: Substring) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break }
        }
        return n
    }

    private static func run(of c: Character, in s: Substring) -> Int {
        s.prefix(while: { $0 == c }).count
    }

    private static func isListItem(_ s: Substring) -> Bool {
        if let c = s.first, "-*+".contains(c), s.dropFirst().first?.isWhitespace ?? true { return true }
        let digits = s.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let rest = s.dropFirst(digits.count)
        return (rest.first == "." || rest.first == ")") && (rest.dropFirst().first?.isWhitespace ?? true)
    }

    private static func inlineDestinations(in line: Substring) -> [(range: Range<String.Index>, destination: String)] {
        var out: [(range: Range<String.Index>, destination: String)] = []
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\\" {
                i = line.index(after: i)
                if i < line.endIndex { i = line.index(after: i) }
                continue
            }
            if c == "`" {
                let n = run(of: "`", in: line[i...])
                let afterOpen = line.index(i, offsetBy: n)
                i = closingBackticks(n, in: line[afterOpen...]) ?? afterOpen
                continue
            }
            if c == "]", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "(" {
                let start = line.index(i, offsetBy: 2)
                if let found = destination(in: line[start...]) { out.append(found) }
                i = start
                continue
            }
            i = line.index(after: i)
        }
        return out
    }

    /// The index just past a run of exactly `n` backticks, or nil if there is none.
    private static func closingBackticks(_ n: Int, in s: Substring) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "`" {
                let m = run(of: "`", in: s[i...])
                let end = s.index(i, offsetBy: m)
                if m == n { return end }
                i = end
            } else {
                i = s.index(after: i)
            }
        }
        return nil
    }

    /// Parses `dest "title")` right after `](`.
    private static func destination(in s: Substring) -> (range: Range<String.Index>, destination: String)? {
        var j = s.startIndex
        while j < s.endIndex, s[j] == " " { j = s.index(after: j) }
        guard j < s.endIndex else { return nil }
        let range: Range<String.Index>
        var k: String.Index
        if s[j] == "<" {
            let open = s.index(after: j)
            guard let close = s[open...].firstIndex(of: ">") else { return nil }
            range = open..<close
            k = s.index(after: close)
        } else {
            var depth = 0
            k = j
            scan: while k < s.endIndex {
                switch s[k] {
                case "\\":
                    k = s.index(after: k)
                case "(":
                    depth += 1
                case ")":
                    if depth == 0 { break scan }
                    depth -= 1
                case let ch where ch.isWhitespace:
                    break scan
                default:
                    break
                }
                if k < s.endIndex { k = s.index(after: k) }
            }
            range = j..<k
        }
        guard !range.isEmpty else { return nil }
        // Optional title, then the closing parenthesis.
        while k < s.endIndex, s[k].isWhitespace { k = s.index(after: k) }
        if k < s.endIndex, let close: Character = ["\"": "\"", "'": "'", "(": ")"][s[k]] {
            guard let end = s[s.index(after: k)...].firstIndex(of: close) else { return nil }
            k = s.index(after: end)
            while k < s.endIndex, s[k].isWhitespace { k = s.index(after: k) }
        }
        guard k < s.endIndex, s[k] == ")" else { return nil }
        return (range, String(s[range]))
    }
}

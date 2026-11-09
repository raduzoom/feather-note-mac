/// Finds inline link and image destinations in Markdown, skipping code.
/// A scanner for the cases import needs, not a CommonMark parser.
enum MarkdownLinks {
    static func destinations(in body: String) -> [(range: Range<String.Index>, destination: String)] {
        var out: [(range: Range<String.Index>, destination: String)] = []
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
            out += inlineDestinations(in: line)
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

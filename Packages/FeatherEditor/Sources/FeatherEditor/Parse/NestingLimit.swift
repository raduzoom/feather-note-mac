import Foundation

/// Caps how deeply Markdown can nest before it reaches the parser.
///
/// swift-markdown and `Builder` recurse once per nesting level, so ten thousand `>` or `![` overflow the
/// stack. The parser reads a copy in which every opener beyond `depth` levels is replaced by `x`. That is an
/// ASCII-for-ASCII swap, so UTF-8 and UTF-16 offsets are unchanged and ranges still point into the real text;
/// the extra levels simply render as plain characters. Ordinary Markdown is returned unchanged.
enum NestingLimit {
    static let depth = 32

    static func apply(_ text: String) -> String {
        var b = Array(text.utf8)
        guard limit(&b) else { return text }
        return String(decoding: b, as: UTF8.self)
    }

    /// Rewrites `b` in place; returns whether anything changed.
    private static func limit(_ b: inout [UInt8]) -> Bool {
        let x: UInt8 = 0x78
        let n = b.count
        var changed = false
        var bracket = 0, star = 0, under = 0
        var i = 0
        var lineStart = true

        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        while i < n {
            if lineStart {
                lineStart = false
                var j = i
                while j < n && (b[j] == 0x20 || b[j] == 0x09) { j += 1 }
                if j == n || b[j] == 0x0A || b[j] == 0x0D { bracket = 0; star = 0; under = 0 }   // blank line ends inline nesting
                i = containerPrefix(&b, from: i, changed: &changed)
                continue
            }
            let c = b[i]
            switch c {
            case 0x0D:
                i += (i + 1 < n && b[i + 1] == 0x0A) ? 2 : 1
                lineStart = true
            case 0x0A:
                i += 1
                lineStart = true
            case 0x5C:   // backslash escape: the next character is literal (a line break still ends the line)
                i += (i + 1 < n && b[i + 1] != 0x0A && b[i + 1] != 0x0D) ? 2 : 1
            case 0x5B:   // [
                bracket += 1
                if bracket > depth { b[i] = x; changed = true }
                i += 1
            case 0x5D:   // ]
                bracket = max(0, bracket - 1)
                i += 1
            case 0x2A, 0x5F:   // * _
                var r = i
                while r < n && b[r] == c { r += 1 }
                let before: UInt8 = i > 0 ? b[i - 1] : 0x20
                let after: UInt8 = r < n ? b[r] : 0x20
                let opens = !isSpace(after), closes = !isSpace(before)
                var count = c == 0x2A ? star : under
                if opens && !closes {
                    for p in i..<r {
                        count += 1
                        if count > depth { b[p] = x; changed = true }
                    }
                } else if closes && !opens {
                    count = max(0, count - (r - i))
                }
                if c == 0x2A { star = count } else { under = count }
                i = r
            default:
                i += 1
            }
        }
        return changed
    }

    /// Skips a line's container markers (`>` and list markers, each after up to three spaces), replacing
    /// those beyond `depth` with `x`; returns the index after the prefix.
    private static func containerPrefix(_ b: inout [UInt8], from start: Int, changed: inout Bool) -> Int {
        let n = b.count
        var i = start
        var level = 0
        while true {
            var k = i, spaces = 0
            while k < n && b[k] == 0x20 && spaces < 3 { k += 1; spaces += 1 }
            guard k < n else { return k }
            var end = k
            if b[k] == 0x3E {   // >
                end = k + 1
            } else if b[k] == 0x2D || b[k] == 0x2B || b[k] == 0x2A {   // - + *
                end = k + 1
                guard end < n, b[end] == 0x20 || b[end] == 0x09 else { return i }
            } else if b[k] >= 0x30 && b[k] <= 0x39 {   // 1. or 1)
                var d = k
                while d < n && d - k < 9 && b[d] >= 0x30 && b[d] <= 0x39 { d += 1 }
                guard d < n, b[d] == 0x2E || b[d] == 0x29, d + 1 < n, b[d + 1] == 0x20 || b[d + 1] == 0x09 else { return i }
                end = d + 1
            } else {
                return i
            }
            level += 1
            if level > depth {
                b[k] = 0x78   // the rest of the line is now paragraph text
                changed = true
                return k + 1
            }
            i = end < n && (b[end] == 0x20 || b[end] == 0x09) ? end + 1 : end   // one space or tab after a marker
        }
    }
}

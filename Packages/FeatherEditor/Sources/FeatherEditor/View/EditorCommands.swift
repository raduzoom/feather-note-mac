import Foundation

/// Word-processor behaviour as pure text edits. Each returns nil when it doesn't apply (default handling then).
public enum EditorCommands {
    public struct Edit: Equatable {
        public var range: NSRange
        public var replacement: String
        public var selection: NSRange
    }

    struct Line {
        var range: NSRange        // without the line ending
        var ending: String        // "\n", "\r\n", "\r" or ""
        var text: String
    }

    static func line(_ s: NSString, at p: Int) -> Line {
        var start = min(p, s.length)
        while start > 0 { let c = s.character(at: start - 1); if c == 0x0A || c == 0x0D { break }; start -= 1 }
        var end = start
        while end < s.length { let c = s.character(at: end); if c == 0x0A || c == 0x0D { break }; end += 1 }
        var ending = ""
        if end < s.length {
            ending = s.character(at: end) == 0x0D && end + 1 < s.length && s.character(at: end + 1) == 0x0A ? "\r\n"
                : (s.character(at: end) == 0x0D ? "\r" : "\n")
        }
        let r = NSRange(location: start, length: end - start)
        return Line(range: r, ending: ending, text: s.substring(with: r))
    }

    /// A list item's first line: indentation, bullet ("-", "1."), spacing and checkbox.
    struct ItemMarker {
        var indent: String
        var bullet: String
        var spacing: String
        var checkbox: String?
        var length: Int { (indent + bullet + spacing + (checkbox ?? "")).utf16.count }
        var bulletWidth: Int { bullet.utf16.count + 1 }
    }

    static let itemPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+|$)(\[[ xX]\][ \t]+|\[[ xX]\]$)?"#)

    static func itemMarker(_ line: Line) -> ItemMarker? {
        let ns = line.text as NSString
        guard let m = itemPattern.firstMatch(in: line.text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        return ItemMarker(indent: g(1) ?? "", bullet: g(2) ?? "-", spacing: g(3) ?? "", checkbox: g(4))
    }

    static func codeContent(_ document: MarkdownDocument, containing p: Int) -> NSRange? {
        for b in document.blocks {
            if case .codeBlock(_, let content) = b.kind, p >= content.location, p <= NSMaxRange(content), content.length > 0 || p == content.location {
                return content
            }
        }
        return nil
    }

    static func leadingWhitespace(_ s: String) -> String { String(s.prefix { $0 == " " || $0 == "\t" }) }

    static func nextBullet(_ bullet: String) -> String {
        guard let last = bullet.last, last == "." || last == ")", let n = Int(bullet.dropLast()) else { return bullet }
        return "\(n + 1)\(last)"
    }

    // MARK: Commands

    public static func returnKey(text: String, document: MarkdownDocument, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let s = text as NSString
        let p = selection.location
        let l = line(s, at: p)
        let newline = l.ending.isEmpty ? previousEnding(s, before: l.range.location) : l.ending
        if codeContent(document, containing: p) != nil {
            let insert = newline + leadingWhitespace(l.text)
            return Edit(range: NSRange(location: p, length: 0), replacement: insert, selection: NSRange(location: p + insert.utf16.count, length: 0))
        }
        guard let m = itemMarker(l) else { return nil }
        let markerEnd = l.range.location + m.length
        guard p >= markerEnd else { return nil }
        let rest = s.substring(with: NSRange(location: markerEnd, length: NSMaxRange(l.range) - markerEnd))
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // empty item: the list ends here
            return Edit(range: NSRange(location: l.range.location, length: NSMaxRange(l.range) - l.range.location), replacement: "",
                        selection: NSRange(location: l.range.location, length: 0))
        }
        let marker = m.indent + nextBullet(m.bullet) + (m.spacing.isEmpty ? " " : m.spacing) + (m.checkbox != nil ? "[ ] " : "")
        let insert = newline + marker
        return Edit(range: NSRange(location: p, length: 0), replacement: insert, selection: NSRange(location: p + insert.utf16.count, length: 0))
    }

    public static func tab(text: String, document: MarkdownDocument, selection: NSRange) -> Edit? {
        let s = text as NSString
        let p = selection.location
        if codeContent(document, containing: p) != nil {
            return Edit(range: selection, replacement: "    ", selection: NSRange(location: p + 4, length: 0))
        }
        let l = line(s, at: p)
        guard let m = itemMarker(l), let previous = previousItem(s, before: l.range.location) else { return nil }
        let target = previous.indent.utf16.count + previous.bulletWidth
        let current = m.indent.utf16.count
        guard target > current else { return nil }
        let add = String(repeating: " ", count: target - current)
        return Edit(range: NSRange(location: l.range.location, length: 0), replacement: add,
                    selection: NSRange(location: selection.location + add.utf16.count, length: selection.length))
    }

    public static func backtab(text: String, document: MarkdownDocument, selection: NSRange) -> Edit? {
        let s = text as NSString
        let p = selection.location
        let l = line(s, at: p)
        if codeContent(document, containing: p) != nil {
            let spaces = min(4, l.text.prefix { $0 == " " }.count)
            guard spaces > 0 else { return nil }
            return Edit(range: NSRange(location: l.range.location, length: spaces), replacement: "",
                        selection: NSRange(location: max(l.range.location, p - spaces), length: 0))
        }
        guard let m = itemMarker(l) else { return nil }
        let current = m.indent.utf16.count
        guard current > 0 else { return nil }
        var target = 0
        var start = l.range.location
        while start > 0 {
            let prev = line(s, at: start - 1)
            if prev.text.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if let pm = itemMarker(prev), pm.indent.utf16.count < current { target = pm.indent.utf16.count; break }
            start = prev.range.location
        }
        let remove = current - target
        return Edit(range: NSRange(location: l.range.location, length: remove), replacement: "",
                    selection: NSRange(location: max(l.range.location, p - remove), length: selection.length))
    }

    public static func backspaceAtItemStart(text: String, document: MarkdownDocument, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let s = text as NSString
        let p = selection.location
        guard codeContent(document, containing: p) == nil else { return nil }
        let l = line(s, at: p)
        var markerLength: Int?
        if let m = itemMarker(l) { markerLength = m.length }
        else if let q = l.text.range(of: #"^[ ]{0,3}(>[ ]?)+"#, options: .regularExpression) {
            markerLength = (String(l.text[q]) as NSString).length
        }
        guard let len = markerLength, len > 0, p == l.range.location + len else { return nil }
        return Edit(range: NSRange(location: l.range.location, length: len), replacement: "", selection: NSRange(location: l.range.location, length: 0))
    }

    public static func toggleCheckbox(text: String, document: MarkdownDocument, at location: Int) -> Edit? {
        for b in document.blocks where location >= b.range.location && location <= NSMaxRange(b.range) {
            guard case .listItem(_, _, let box?) = b.kind else { continue }
            switch box {
            case .unchecked(let r): return Edit(range: r, replacement: "[x]", selection: NSRange(location: NSMaxRange(r), length: 0))
            case .checked(let r): return Edit(range: r, replacement: "[ ]", selection: NSRange(location: NSMaxRange(r), length: 0))
            }
        }
        return nil
    }

    // MARK: Helpers

    static func previousItem(_ s: NSString, before lineStart: Int) -> ItemMarker? {
        var start = lineStart
        while start > 0 {
            let prev = line(s, at: start - 1)
            if prev.text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            if let m = itemMarker(prev) { return m }
            start = prev.range.location
        }
        return nil
    }

    static func previousEnding(_ s: NSString, before lineStart: Int) -> String {
        guard lineStart > 0 else { return "\n" }
        if lineStart >= 2, s.character(at: lineStart - 2) == 0x0D, s.character(at: lineStart - 1) == 0x0A { return "\r\n" }
        return s.character(at: lineStart - 1) == 0x0D ? "\r" : "\n"
    }
}

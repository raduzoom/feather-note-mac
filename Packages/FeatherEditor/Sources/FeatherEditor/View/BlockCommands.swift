import Foundation

/// The block menu's edits (design spec "Notes" › Block menu). Each one replaces the caret's line, so a pick and
/// the removal of its "/query" trigger are one undo step.
extension EditorCommands {
    static let headingMarker = try! NSRegularExpression(pattern: #"^[ \t]*#{1,6}(?:[ \t]+|$)"#)
    static let quoteMarker = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ ]?)+"#)

    /// A line's leading whitespace, the block markers after it (headings, quote prefixes, list markers with
    /// their checkbox, in any order and repeated), and the text that follows.
    static func splitMarkers(_ text: String) -> (indent: String, markers: String, content: String) {
        let indent = leadingWhitespace(text)
        var rest = String(text.dropFirst(indent.count))
        var markers = ""
        while true {
            let ns = rest as NSString
            let whole = NSRange(location: 0, length: ns.length)
            var length = 0
            for pattern in [headingMarker, quoteMarker, itemPattern] {
                if let m = pattern.firstMatch(in: rest, range: whole), m.range.length > 0 { length = m.range.length; break }
            }
            guard length > 0 else { break }
            markers += ns.substring(to: length)
            rest = ns.substring(from: length)
        }
        return (indent, markers, rest)
    }

    /// What lines added below `line` start with, so they stay in its container: a list item's content indent,
    /// a quote's ">" run, or the line's leading whitespace.
    static func containerPrefix(_ line: Line) -> String {
        if let m = itemMarker(line) {
            return m.indent + String(repeating: " ", count: m.bullet.utf16.count + max(1, m.spacing.utf16.count))
        }
        let ns = line.text as NSString
        if let q = quoteMarker.firstMatch(in: line.text, range: NSRange(location: 0, length: ns.length)) {
            let prefix = ns.substring(with: q.range)
            return prefix.hasSuffix(" ") ? prefix : prefix + " "
        }
        return leadingWhitespace(line.text)
    }

    /// The caret's line with `trigger` (inside it) removed.
    private static func lineWithout(_ trigger: NSRange?, in s: NSString, caret: Int) -> Line {
        var l = line(s, at: caret)
        if let t = trigger, t.location >= l.range.location, NSMaxRange(t) <= NSMaxRange(l.range) {
            l.text = (l.text as NSString).replacingCharacters(in: NSRange(location: t.location - l.range.location, length: t.length), with: "")
        }
        return l
    }

    /// The edit for a block choice at the caret, removing `trigger` (the typed "/query") in the same edit.
    /// Nil for image or file and scan, which the view inserts once the file arrives.
    public static func block(_ choice: BlockChoice, text: String, caret: Int, removing trigger: NSRange?) -> Edit? {
        let s = text as NSString
        let l = lineWithout(trigger, in: s, caret: caret)
        let nl = l.ending.isEmpty ? previousEnding(s, before: l.range.location) : l.ending
        let (indent, _, content) = splitMarkers(l.text)
        let isEmpty = content.trimmingCharacters(in: .whitespaces).isEmpty
        func edit(_ before: String, _ after: String = "") -> Edit {
            Edit(range: l.range, replacement: before + after, selection: NSRange(location: l.range.location + (before as NSString).length, length: 0))
        }

        if choice.isTextBlock {
            return edit(indent + marker(choice, s: s, lineStart: l.range.location, indent: indent) + content)
        }
        // Code and divider: on an empty line they replace it, markers included; below a line with text they
        // keep its container.
        let prefix = isEmpty ? indent : containerPrefix(l)
        let blank = String(prefix.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        let head = isEmpty ? "" : l.text + nl
        switch choice {
        case .code:
            return edit(head + prefix + "```" + nl + prefix, nl + prefix + "```")
        case .divider:
            // a divider right under text would make that text a setext heading
            let needsBlank = !isEmpty || !previousLineIsBlank(s, before: l.range.location)
            return edit(head + (needsBlank ? blank + nl : "") + prefix + "---" + nl + prefix)
        default:
            return nil
        }
    }

    /// Where an image, file or scan goes: the line itself once the trigger is removed and nothing but markers
    /// is left (the edit then clears the line), otherwise the line's end. `location` is in the text after `edit`.
    static func mediaInsertionPoint(text: String, caret: Int, removing trigger: NSRange?) -> (edit: Edit?, location: Int) {
        let s = text as NSString
        let l = lineWithout(trigger, in: s, caret: caret)
        if splitMarkers(l.text).content.trimmingCharacters(in: .whitespaces).isEmpty {
            let clear = l.range.length == 0 ? nil : Edit(range: l.range, replacement: "", selection: NSRange(location: l.range.location, length: 0))
            return (clear, l.range.location)
        }
        let removal = trigger.map { t in Edit(range: t, replacement: "", selection: NSRange(location: t.location, length: 0)) }
        return (removal, l.range.location + l.text.utf16.count)
    }

    private static func marker(_ choice: BlockChoice, s: NSString, lineStart: Int, indent: String) -> String {
        switch choice {
        case .heading1: return "# "
        case .heading2: return "## "
        case .heading3: return "### "
        case .bulleted: return "- "
        case .todo: return "- [ ] "
        case .quote: return "> "
        case .numbered:
            if let p = previousItem(s, before: lineStart), p.indent == indent, p.bullet.last == "." || p.bullet.last == ")" {
                return nextBullet(p.bullet) + " "
            }
            return "1. "
        default: return ""
        }
    }

    private static func previousLineIsBlank(_ s: NSString, before lineStart: Int) -> Bool {
        guard lineStart > 0 else { return true }
        let prev = line(s, at: lineStart - previousEnding(s, before: lineStart).utf16.count)
        return prev.text.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension EditorCommands {
    /// Whether a "/" typed at `slashAt` opens the block menu: only where its line's text begins (nothing but
    /// whitespace and block markers before it), never in code or in a block shown as source (HTML, tables).
    static func slashOpensMenu(text: String, document: MarkdownDocument, slashAt: Int) -> Bool {
        let s = text as NSString
        let l = line(s, at: slashAt)
        let before = s.substring(with: NSRange(location: l.range.location, length: slashAt - l.range.location))
        guard splitMarkers(before).content.isEmpty, codeContent(document, containing: slashAt) == nil else { return false }
        return !document.blocks.contains { b in
            if case .unrendered = b.kind { return slashAt >= b.range.location && slashAt <= NSMaxRange(b.range) }
            if case .codeBlock = b.kind { return slashAt > b.range.location && slashAt < NSMaxRange(b.range) }
            return false
        }
    }
}

extension EditorCommands {
    /// Inserts attachment snippets from the block menu as blocks of their own, so an image shows as an
    /// image: on an empty line (`location` at its start) they replace it; at the end of a line with text
    /// they go below it in its container. Blank lines separate them from text above and below (an image
    /// sharing a paragraph with text is a chip), and every new line uses the line's own ending.
    static func mediaEdit(_ snippets: [String], text: String, at location: Int) -> Edit {
        let s = text as NSString
        let l = line(s, at: location)
        let nl = l.ending.isEmpty ? previousEnding(s, before: l.range.location) : l.ending
        let empty = splitMarkers(l.text).content.trimmingCharacters(in: .whitespaces).isEmpty
        let prefix = empty ? leadingWhitespace(l.text) : containerPrefix(l)
        let blank = String(prefix.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        let body = snippets.map { prefix + $0 }.joined(separator: nl + blank + nl)
        let after = nextLineIsBlank(s, after: l) ? "" : nl + blank
        let range: NSRange
        let before: String
        if empty {
            range = l.range
            before = previousLineIsBlank(s, before: l.range.location) ? "" : blank + nl
        } else {
            range = NSRange(location: NSMaxRange(l.range), length: 0)
            before = nl + blank + nl
        }
        let end = range.location + (before + body as NSString).length
        return Edit(range: range, replacement: before + body + after, selection: NSRange(location: end, length: 0))
    }

    private static func nextLineIsBlank(_ s: NSString, after l: Line) -> Bool {
        guard !l.ending.isEmpty else { return true }
        return line(s, at: NSMaxRange(l.range) + l.ending.utf16.count).text.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

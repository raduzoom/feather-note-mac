import Foundation

/// Keeps a parsed document current as the text changes, re-parsing only the region an edit touches.
///
/// The region runs between "safe boundaries": a line start with no indentation, after a blank line
/// (or the start of the text), and outside any code block. A block starting there parses the same on
/// its own as inside the whole document. Fences, unclosed fences and link reference definitions
/// (which reach across the whole note) fall back to parsing to the end, or the whole note.
public final class IncrementalParser {
    public private(set) var document: MarkdownDocument
    private var text: NSString
    /// How many link reference definitions the text holds; kept current per edit so typing never scans the note.
    private(set) var referenceDefinitionCount: Int

    public init(text: String) {
        self.text = text as NSString
        document = MarkdownParser.parse(text)
        referenceDefinitionCount = Self.countReferenceDefinitions(text as NSString)
    }

    /// Applies an edit (`edit` in the old text, replaced by `replacementLength` characters giving `newText`).
    /// Returns the range of `newText` whose spans were re-parsed: the range to restyle.
    @discardableResult
    public func apply(edit: NSRange, replacementLength: Int, newText: String) -> NSRange {
        let new = newText as NSString
        let delta = replacementLength - edit.length
        let oldText = text
        text = new
        let whole = NSRange(location: 0, length: new.length)

        let oldCount = referenceDefinitionCount
        referenceDefinitionCount = Self.updatedReferenceCount(oldCount, old: oldText, new: new, edit: edit, replacementLength: replacementLength)
        if referenceDefinitionCount > 0 || oldCount > 0 {
            document = MarkdownParser.parse(newText)
            return whole
        }

        // Old blocks with ranges moved into new coordinates; blocks overlapping the edit are dropped later.
        let editEndNew = edit.location + replacementLength
        let codeRanges: [NSRange] = document.blocks.compactMap { b in
            guard case .codeBlock = b.kind else { return nil }
            if NSMaxRange(b.range) <= edit.location { return b.range }
            if b.range.location >= NSMaxRange(edit) { return b.range.shifted(by: delta) }
            return NSRange(location: b.range.location, length: max(0, NSMaxRange(b.range) + delta - b.range.location))
        }

        let old = document.blocks
        // The region's start must be a safe boundary in the new text that no old block spans.
        var start = Self.safeBoundary(in: new, atOrBefore: edit.location, avoiding: codeRanges)
        // An unclosed fence or HTML block before the edit reaches to the end of the note (cmark leaves its
        // trailing blank lines out of its range, so they look like safe boundaries): reparse from it to the end.
        var toEnd = false
        if let open = old.first(where: { $0.range.location <= edit.location && Self.runsToEnd($0, in: oldText) }) {
            start = min(start, Self.safeBoundary(in: new, atOrBefore: open.range.location, avoiding: []))
            toEnd = true
        }
        while start > 0, old.contains(where: { $0.range.location < start && NSMaxRange($0.range) > start }) {
            start = Self.safeBoundary(in: new, atOrBefore: start - 1, avoiding: codeRanges)
        }
        // Its end must be a safe boundary whose old position is a clean block boundary after the edit.
        var end = Self.safeBoundary(in: new, after: editEndNew, avoiding: codeRanges)
        while end < new.length {
            let oldPos = end - delta
            let clean = oldPos >= NSMaxRange(edit)
                && !old.contains(where: { $0.range.location < oldPos && NSMaxRange($0.range) > oldPos })
            if clean { break }
            end = Self.safeBoundary(in: new, after: end, avoiding: codeRanges)
        }

        // A fence typed or deleted changes everything below it.
        let touched = Self.lineRange(in: oldText, NSRange(location: edit.location, length: edit.length))
        let touchedNew = Self.lineRange(in: new, NSRange(location: edit.location, length: replacementLength))
        if toEnd || Self.hasFence(oldText.substring(with: touched)) || Self.hasFence(new.substring(with: touchedNew))
            || Self.hasHTMLBlockToken(oldText.substring(with: touched)) || Self.hasHTMLBlockToken(new.substring(with: touchedNew)) {
            end = new.length
        }

        var region = NSRange(location: start, length: end - start)
        var reparsed = MarkdownParser.parse(newText, in: region)
        if end < new.length, reparsed.contains(where: { Self.runsToEnd($0, in: new) }) {
            end = new.length
            region = NSRange(location: start, length: end - start)
            reparsed = MarkdownParser.parse(newText, in: region)
        }

        let oldEnd = end - delta
        let before = old.filter { NSMaxRange($0.range) <= start }
        let after = end < new.length ? old.filter { $0.range.location >= oldEnd }.map { $0.shifted(by: delta) } : []
        document = MarkdownDocument(blocks: before + reparsed + after)
        return region
    }

    // MARK: Helpers

    /// HTML block kinds 1–5 (comments, <pre>, <script>, <style>, <textarea>, <? ?>, <!X>, CDATA): they continue
    /// across blank lines until their closer, so typing or deleting an opener or closer changes everything below.
    static let htmlBlockToken = try! NSRegularExpression(pattern: #"<!--|-->|<\?|\?>|<!\[CDATA\[|\]\]>|<![A-Za-z]|</?(pre|script|style|textarea)\b"#, options: [.caseInsensitive])

    static func hasHTMLBlockToken(_ s: String) -> Bool {
        htmlBlockToken.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// A block that, unclosed, swallows the rest of the note: a fence without its closing fence, or an
    /// HTML block of kinds 1–5 without its closer.
    static func runsToEnd(_ b: Block, in text: NSString) -> Bool {
        switch b.kind {
        case .codeBlock:
            let fences = b.markers.filter { m in
                guard NSMaxRange(m) <= text.length else { return false }
                let t = text.substring(with: m).trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("```") || t.hasPrefix("~~~")
            }
            return fences.count == 1
        case .unrendered:
            guard NSMaxRange(b.range) <= text.length else { return false }
            let body = text.substring(with: b.range).trimmingCharacters(in: .whitespaces).lowercased()
            let pairs: [(String, [String])] = [("<!--", ["-->"]), ("<?", ["?>"]), ("<![cdata[", ["]]>"]), ("<!", [">"]),
                                                ("<pre", ["</pre>"]), ("<script", ["</script>"]), ("<style", ["</style>"]), ("<textarea", ["</textarea>"])]
            guard let (_, closers) = pairs.first(where: { body.hasPrefix($0.0) }) else { return false }
            let afterOpener = body.dropFirst(2)
            return !closers.contains { afterOpener.contains($0) }
        default:
            return false
        }
    }

    static func isUnclosedFence(_ b: Block) -> Bool {
        guard case .codeBlock = b.kind else { return false }
        return b.markers.count == 1
    }

    static func hasFence(_ s: String) -> Bool { s.contains("```") || s.contains("~~~") }

    /// Every link reference definition contains `]:` (its label may span lines and sit inside quotes or list
    /// items), so the note is parsed in full while it holds any `]:`. Counting a two-character token keeps the
    /// per-edit recount exact; matching too much only costs a full parse.
    static let referenceDefinition = try! NSRegularExpression(pattern: #"\]:"#)

    static func countReferenceDefinitions(_ s: NSString, in range: NSRange? = nil) -> Int {
        referenceDefinition.numberOfMatches(in: s as String, range: range ?? NSRange(location: 0, length: s.length))
    }

    /// Recounts only the edited lines (plus one line either side, so CRLF splits can't move a line boundary).
    /// Each definition lies within one line, so the rest of the text contributes the same count before and after.
    static func updatedReferenceCount(_ count: Int, old: NSString, new: NSString, edit: NSRange, replacementLength: Int) -> Int {
        func widened(_ s: NSString, _ r: NSRange) -> NSRange {
            var lines = lineRange(in: s, r)
            if lines.location > 0 { lines = NSUnionRange(lines, lineRange(in: s, NSRange(location: lines.location - 1, length: 0))) }
            if NSMaxRange(lines) < s.length { lines = NSUnionRange(lines, lineRange(in: s, NSRange(location: NSMaxRange(lines), length: 0))) }
            return lines
        }
        let o = widened(old, edit), n = widened(new, NSRange(location: edit.location, length: replacementLength))
        let start = min(o.location, n.location)
        let tail = min(old.length - NSMaxRange(o), new.length - NSMaxRange(n))
        let oldSpan = NSRange(location: start, length: old.length - tail - start)
        let newSpan = NSRange(location: start, length: new.length - tail - start)
        return count - countReferenceDefinitions(old, in: oldSpan) + countReferenceDefinitions(new, in: newSpan)
    }

    /// The full lines covering `r`.
    static func lineRange(in s: NSString, _ r: NSRange) -> NSRange {
        let clamped = NSRange(location: min(r.location, s.length), length: max(0, min(r.length, s.length - min(r.location, s.length))))
        return s.lineRange(for: clamped)
    }

    static func lineStart(in s: NSString, at i: Int) -> Int {
        var j = min(i, s.length)
        while j > 0 { let c = s.character(at: j - 1); if c == 0x0A || c == 0x0D { break }; j -= 1 }
        return j
    }

    static func isBlank(_ s: NSString, lineEndingBefore i: Int) -> Bool {
        // the line ending just before index i: is the line before it empty or whitespace?
        guard i > 0 else { return true }
        var j = i - 1
        if s.character(at: j) == 0x0A, j > 0, s.character(at: j - 1) == 0x0D { j -= 1 }
        let prevStart = lineStart(in: s, at: j)
        for k in prevStart..<j { let c = s.character(at: k); if c != 0x20 && c != 0x09 { return false } }
        return true
    }

    static func isSafe(_ s: NSString, lineStart i: Int, avoiding code: [NSRange]) -> Bool {
        if i == 0 { return true }
        if i >= s.length { return true }
        let c = s.character(at: i)
        if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { return false }
        if !isBlank(s, lineEndingBefore: i) { return false }
        // a blank line itself must not be the previous-previous... also not inside a code block
        return !code.contains { $0.location < i && i < NSMaxRange($0) }
    }

    static func safeBoundary(in s: NSString, atOrBefore i: Int, avoiding code: [NSRange]) -> Int {
        var start = lineStart(in: s, at: i)
        while start > 0 {
            if isSafe(s, lineStart: start, avoiding: code) { return start }
            start = lineStart(in: s, at: start - 1)
        }
        return 0
    }

    static func safeBoundary(in s: NSString, after i: Int, avoiding code: [NSRange]) -> Int {
        var j = min(i, s.length)
        // move to the start of the next line
        while j < s.length { let c = s.character(at: j); j += 1; if c == 0x0A || (c == 0x0D && (j >= s.length || s.character(at: j) != 0x0A)) { break } }
        while j < s.length {
            if isSafe(s, lineStart: j, avoiding: code) { return j }
            while j < s.length { let c = s.character(at: j); j += 1; if c == 0x0A || (c == 0x0D && (j >= s.length || s.character(at: j) != 0x0A)) { break } }
        }
        return s.length
    }
}

import Foundation
import Markdown

/// Turns Markdown text into ranges, using swift-markdown (cmark-gfm) for the grammar.
public enum MarkdownParser {
    public static func parse(_ text: String) -> MarkdownDocument {
        MarkdownDocument(blocks: parse(text, in: NSRange(location: 0, length: (text as NSString).length)))
    }

    /// Parses `range` of `text` on its own and returns blocks with ranges in `text`.
    public static func parse(_ text: String, in range: NSRange) -> [Block] {
        let piece = (text as NSString).substring(with: range)
        var builder = Builder(text: piece)
        builder.visitChildren(of: Document(parsing: NestingLimit.apply(piece)), context: ParseContext())
        guard range.location != 0 else { return builder.blocks }
        return builder.blocks.map { $0.shifted(by: range.location) }
    }
}

extension NSRange {
    func shifted(by delta: Int) -> NSRange { NSRange(location: location + delta, length: length) }
}

extension Block {
    func shifted(by delta: Int) -> Block {
        var b = self
        b.range = range.shifted(by: delta)
        b.markers = markers.map { $0.shifted(by: delta) }
        b.inlines = inlines.map { Inline(kind: $0.kind, range: $0.range.shifted(by: delta), markers: $0.markers.map { $0.shifted(by: delta) }) }
        switch kind {
        case .listItem(let o, let d, .checked(let r)): b.kind = .listItem(ordered: o, depth: d, checkbox: .checked(r.shifted(by: delta)))
        case .listItem(let o, let d, .unchecked(let r)): b.kind = .listItem(ordered: o, depth: d, checkbox: .unchecked(r.shifted(by: delta)))
        case .codeBlock(let l, let c): b.kind = .codeBlock(language: l, contentRange: c.shifted(by: delta))
        case .image(let a, let u, let s): b.kind = .image(alt: a, url: u, sourceRange: s.shifted(by: delta))
        default: break
        }
        return b
    }
}

/// Converts swift-markdown's (line, UTF-8 column) locations into UTF-16 offsets.
struct LocationMap {
    let ns: NSString
    let utf8: [UInt8]
    /// Per line (0-based): UTF-8 offset and UTF-16 offset of its first character.
    private(set) var lineStarts: [(utf8: Int, utf16: Int)] = []
    /// (UTF-8, UTF-16) offsets at character starts, at least every 64 bytes, ascending; empty for ASCII text.
    /// Converting a column walks at most 64 bytes from the nearest checkpoint, so long lines stay linear.
    private var checkpoints: [(utf8: Int, utf16: Int)] = []

    init(_ text: String) {
        ns = text as NSString
        utf8 = Array(text.utf8)
        let ascii = utf8.count == ns.length
        var starts = [(0, 0)]
        var marks = [(0, 0)]
        var u16 = 0
        var i = 0
        while i < utf8.count {
            if !ascii && i >= marks[marks.count - 1].0 + 64 { marks.append((i, u16)) }
            let b = utf8[i]
            let width = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
            u16 += width == 4 ? 2 : 1
            i += width
            if b == 0x0A || (b == 0x0D && (i >= utf8.count || utf8[i] != 0x0A)) { starts.append((i, u16)) }
        }
        lineStarts = starts
        checkpoints = ascii ? [] : marks
    }

    /// UTF-16 offset of a 1-based (line, column) location; clamped to the text.
    func offset(_ loc: SourceLocation) -> Int {
        let line = min(max(loc.line - 1, 0), lineStarts.count - 1)
        let target = min(lineStarts[line].utf8 + max(loc.column - 1, 0), utf8.count)
        if checkpoints.isEmpty { return target }   // ASCII: UTF-8 and UTF-16 offsets agree
        // the last checkpoint at or before the target
        var lo = 0, hi = checkpoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if checkpoints[mid].utf8 <= target { lo = mid } else { hi = mid - 1 }
        }
        var i = checkpoints[lo].utf8
        var u16 = checkpoints[lo].utf16
        while i < target {
            let b = utf8[i]
            let width = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
            u16 += width == 4 ? 2 : 1
            i += width
        }
        return u16
    }

    func range(_ r: SourceRange?) -> NSRange? {
        guard let r else { return nil }
        let a = offset(r.lowerBound), b = offset(r.upperBound)
        return NSRange(location: a, length: max(0, b - a))
    }

    func char(at i: Int) -> unichar? { i >= 0 && i < ns.length ? ns.character(at: i) : nil }
}

struct ParseContext {
    var quoteDepth = 0
    var listDepth = -1
    var ordered = false
    /// Set for the first leaf block of a list item: its marker and checkbox.
    var pendingItem: (marker: NSRange, checkbox: Checkbox?)?
}

struct Builder {
    let map: LocationMap
    var blocks: [Block] = []

    init(text: String) { map = LocationMap(text) }

    mutating func visitChildren(of node: Markup, context: ParseContext) {
        var ctx = context
        for child in node.children {
            visit(child, context: ctx)
            ctx.pendingItem = nil   // only the item's first block carries the marker
        }
    }

    mutating func visit(_ node: Markup, context: ParseContext) {
        guard let range = map.range(node.range) else { return }
        var ctx = context
        switch node {
        case let list as UnorderedList:
            ctx.listDepth += 1; ctx.ordered = false
            visitChildren(of: list, context: ctx)
        case let list as OrderedList:
            ctx.listDepth += 1; ctx.ordered = true
            visitChildren(of: list, context: ctx)
        case let item as ListItem:
            let contentStart = item.children.first(where: { _ in true }).flatMap { map.range($0.range)?.location } ?? NSMaxRange(range)
            let marker = NSRange(location: range.location, length: max(0, contentStart - range.location))
            var checkbox: Checkbox?
            if let c = item.checkbox {
                let s = map.ns.substring(with: marker) as NSString
                let open = s.range(of: "[")
                if open.location != NSNotFound {
                    let r = NSRange(location: marker.location + open.location, length: 3)
                    checkbox = c == .checked ? .checked(r) : .unchecked(r)
                }
            }
            ctx.pendingItem = (marker, checkbox)
            if item.childCount == 0 {
                blocks.append(Block(kind: .listItem(ordered: ctx.ordered, depth: ctx.listDepth, checkbox: checkbox),
                                    range: range, inlines: [], markers: [marker]))
            } else {
                var first = true
                for child in item.children {
                    var c = ctx
                    if !first { c.pendingItem = nil }
                    visit(child, context: c)
                    first = false
                }
            }
        case let quote as BlockQuote:
            ctx.quoteDepth += 1
            visitChildren(of: quote, context: ctx)
        case let heading as Heading:
            append(.heading(level: heading.level), range: range, inlines: inlines(of: heading), markers: headingMarkers(range), ctx)
        case let paragraph as Paragraph:
            if let image = soleImage(paragraph), let imageRange = map.range(image.range) {
                append(.image(alt: image.plainText, url: image.source ?? "", sourceRange: imageRange), range: range, inlines: [], markers: [], ctx)
            } else {
                append(.paragraph, range: range, inlines: inlines(of: paragraph), markers: [], ctx)
            }
        case let code as CodeBlock:
            let (markers, content) = fenceMarkers(range)
            append(.codeBlock(language: code.language.flatMap { $0.isEmpty ? nil : $0 }, contentRange: content), range: range, inlines: [], markers: markers, ctx)
        case is ThematicBreak:
            append(.thematicBreak, range: range, inlines: [], markers: [range], ctx)
        case is HTMLBlock, is Table:
            append(.unrendered, range: range, inlines: [], markers: [], ctx)
        default:
            append(.unrendered, range: range, inlines: [], markers: [], ctx)
        }
    }

    /// Adds a leaf block, turning it into a list item or quote block when the context says so.
    mutating func append(_ kind: BlockKind, range: NSRange, inlines: [Inline], markers: [NSRange], _ ctx: ParseContext) {
        if let item = ctx.pendingItem {
            let start = item.marker.location
            let r = NSRange(location: start, length: NSMaxRange(range) - start)
            let k: BlockKind = (kind == .paragraph) ? .listItem(ordered: ctx.ordered, depth: ctx.listDepth, checkbox: item.checkbox) : kind
            blocks.append(Block(kind: k, range: r, inlines: inlines, markers: [item.marker] + markers))
            return
        }
        if ctx.quoteDepth > 0, kind == .paragraph {
            blocks.append(Block(kind: .quote(depth: ctx.quoteDepth), range: range, inlines: inlines, markers: quotePrefixes(range)))
            return
        }
        blocks.append(Block(kind: kind, range: range, inlines: inlines, markers: markers))
    }

    // MARK: Markers

    func headingMarkers(_ range: NSRange) -> [NSRange] {
        guard map.char(at: range.location) == 0x23 else {   // setext: the underline line
            let s = map.ns.substring(with: range) as NSString
            let lastBreak = s.rangeOfCharacter(from: .newlines, options: .backwards)
            guard lastBreak.location != NSNotFound else { return [] }
            let start = range.location + NSMaxRange(lastBreak)
            return [NSRange(location: start, length: NSMaxRange(range) - start)]
        }
        var i = range.location
        while map.char(at: i) == 0x23 { i += 1 }
        while let c = map.char(at: i), c == 0x20 || c == 0x09, i < NSMaxRange(range) { i += 1 }
        return [NSRange(location: range.location, length: i - range.location)]
    }

    /// "> " prefixes on each line of a quoted paragraph.
    func quotePrefixes(_ range: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var lineStart = range.location
        // back up to the start of the line: the first line's "> " sits before the paragraph's range
        while lineStart > 0, let c = map.char(at: lineStart - 1), c != 0x0A, c != 0x0D { lineStart -= 1 }
        while lineStart < NSMaxRange(range) {
            var i = lineStart
            while let c = map.char(at: i), c == 0x20 || c == 0x3E || c == 0x09 { i += 1 }
            if i > lineStart { out.append(NSRange(location: lineStart, length: i - lineStart)) }
            var e = i
            while let c = map.char(at: e), c != 0x0A, c != 0x0D { e += 1 }
            while let c = map.char(at: e), c == 0x0A || c == 0x0D { e += 1 }
            if e == lineStart { break }
            lineStart = e
        }
        return out
    }

    /// Opening fence line (with its line break) and closing fence line, and the content between.
    func fenceMarkers(_ range: NSRange) -> ([NSRange], NSRange) {
        let s = map.ns.substring(with: range) as NSString
        let first = s.substring(to: min(3, s.length))
        guard first.hasPrefix("```") || first.hasPrefix("~~~") || s.trimmingCharacters(in: .whitespaces).hasPrefix("```") || s.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") else {
            return ([], range)   // indented code: no markers
        }
        let firstBreak = s.rangeOfCharacter(from: .newlines)
        guard firstBreak.location != NSNotFound else { return ([range], NSRange(location: NSMaxRange(range), length: 0)) }
        var openEnd = NSMaxRange(firstBreak)
        if firstBreak.length == 1, openEnd < s.length, s.character(at: firstBreak.location) == 0x0D, s.character(at: openEnd) == 0x0A { openEnd += 1 }
        let open = NSRange(location: range.location, length: openEnd)
        let fenceChar = s.trimmingCharacters(in: .whitespaces).first!
        let lastBreak = s.rangeOfCharacter(from: .newlines, options: .backwards)
        if lastBreak.location != NSNotFound, lastBreak.location >= openEnd - 1 {
            let lastLine = s.substring(from: NSMaxRange(lastBreak)).trimmingCharacters(in: .whitespaces)
            if lastLine.count >= 3, lastLine.allSatisfy({ $0 == fenceChar }) {
                let closeStart = range.location + NSMaxRange(lastBreak)
                let close = NSRange(location: closeStart, length: NSMaxRange(range) - closeStart)
                return ([open, close], NSRange(location: NSMaxRange(open), length: closeStart - NSMaxRange(open)))
            }
        }
        return ([open], NSRange(location: NSMaxRange(open), length: NSMaxRange(range) - NSMaxRange(open)))
    }

    // MARK: Inlines

    func soleImage(_ p: Paragraph) -> Image? {
        let kids = Array(p.children)
        guard kids.count == 1, let image = kids[0] as? Image else { return nil }
        return image
    }

    /// Inline spans of a leaf block. cmark's inline positions are wrong on lazy continuation lines inside
    /// lists and quotes, so a span is kept only if it lies inside the block and every marker is really its
    /// delimiter: the editor must never hide characters that aren't syntax.
    func inlines(of node: Markup) -> [Inline] {
        var out: [Inline] = []
        collect(node, into: &out)
        guard let block = map.range(node.range) else { return [] }
        return out.filter { inline in
            guard inline.range.location >= block.location, NSMaxRange(inline.range) <= NSMaxRange(block) else { return false }
            return valid(inline)
        }
    }

    func valid(_ inline: Inline) -> Bool {
        let parts = inline.markers.map { map.ns.substring(with: $0) }
        func all(_ s: String, in set: Set<Character>) -> Bool { !s.isEmpty && s.allSatisfy(set.contains) }
        switch inline.kind {
        case .strong: return parts.count == 2 && parts.allSatisfy { $0 == "**" || $0 == "__" }
        case .emphasis: return parts.count == 2 && parts.allSatisfy { $0 == "*" || $0 == "_" }
        case .strikethrough: return parts.count == 2 && parts.allSatisfy { all($0, in: ["~"]) }
        case .code: return parts.count == 2 && parts.allSatisfy { all($0, in: ["`"]) }
        case .link: return parts.count == 2 && (parts[0] == "[" || parts[0] == "![") && parts[1].hasPrefix("]")
        case .html: return map.ns.substring(with: inline.range).hasPrefix("<")
        }
    }

    func collect(_ node: Markup, into out: inout [Inline]) {
        for child in node.children {
            if let range = map.range(child.range) {
                switch child {
                case is Strong: out.append(Inline(kind: .strong, range: range, markers: ends(range, 2)))
                case is Emphasis: out.append(Inline(kind: .emphasis, range: range, markers: ends(range, 1)))
                case is Strikethrough:
                    var n = 0
                    while map.char(at: range.location + n) == 0x7E { n += 1 }
                    out.append(Inline(kind: .strikethrough, range: range, markers: ends(range, max(1, n))))
                case is InlineCode:
                    var n = 0
                    while map.char(at: range.location + n) == 0x60 { n += 1 }
                    out.append(Inline(kind: .code, range: range, markers: ends(range, max(1, n))))
                case let link as Link:
                    out.append(Inline(kind: .link(url: link.destination ?? ""), range: range, markers: linkMarkers(link, range, prefix: 1)))
                case let image as Image:
                    out.append(Inline(kind: .link(url: image.source ?? ""), range: range, markers: linkMarkers(image, range, prefix: 2)))
                case is InlineHTML:
                    out.append(Inline(kind: .html, range: range, markers: []))
                default: break
                }
            }
            collect(child, into: &out)
        }
    }

    func ends(_ r: NSRange, _ n: Int) -> [NSRange] {
        guard r.length >= 2 * n else { return [] }
        return [NSRange(location: r.location, length: n), NSRange(location: NSMaxRange(r) - n, length: n)]
    }

    /// "[" (or "![") and everything from "]" to the end.
    func linkMarkers(_ node: Markup, _ r: NSRange, prefix: Int) -> [NSRange] {
        let textEnd = node.children.compactMap { map.range($0.range).map(NSMaxRange) }.max() ?? (r.location + prefix)
        let close = min(max(textEnd, r.location + prefix), NSMaxRange(r))
        return [NSRange(location: r.location, length: prefix), NSRange(location: close, length: NSMaxRange(r) - close)]
    }
}

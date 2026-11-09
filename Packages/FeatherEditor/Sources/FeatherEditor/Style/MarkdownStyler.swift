import AppKit

public enum EditorMode: String, Sendable { case live, raw }

/// One attribute run the editor applies to its text storage.
public struct StyleRun: Equatable {
    public var range: NSRange
    public var attributes: [NSAttributedString.Key: AnyHashable]
}

extension Dictionary where Key == NSAttributedString.Key, Value == AnyHashable {
    public var nsAttributes: [NSAttributedString.Key: Any] { mapValues { $0.base } }
}

/// Turns text plus its parse into attributes. Pure: same input, same runs. It never changes the text.
public enum MarkdownStyler {
    /// Runs covering `range` widened to whole lines.
    /// Blocks longer than this (in UTF-16 units) are shown as plain Markdown in both modes.
    public static let maxStyledBlockLength = 65_536

    public static func runs(text: String, document: MarkdownDocument, selection: NSRange, mode: EditorMode,
                            theme: EditorTheme, in range: NSRange, imageHeight: (String) -> CGFloat = { _ in 96 }) -> [StyleRun] {
        let ns = text as NSString
        let lines = ns.length == 0 ? NSRange(location: 0, length: 0)
            : ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: max(0, min(range.length, ns.length - min(range.location, ns.length)))))
        let scratch = NSMutableAttributedString(string: ns.substring(with: lines))
        let offset = lines.location
        func local(_ r: NSRange) -> NSRange? {
            let i = NSIntersectionRange(r, lines)
            guard i.length > 0 || (r.length == 0 && NSLocationInRange(r.location, lines)) else { return nil }
            return NSRange(location: i.location - offset, length: i.length)
        }
        func set(_ r: NSRange, _ attrs: [NSAttributedString.Key: Any]) {
            guard let l = local(r), l.length > 0 else { return }
            var attrs = attrs
            if let trait = attrs.removeValue(forKey: .featherTrait) as? UInt32 {
                // nested emphasis: OR the traits already there
                scratch.enumerateAttribute(.featherTrait, in: l) { existing, sub, _ in
                    scratch.addAttribute(.featherTrait, value: trait | ((existing as? UInt32) ?? 0), range: sub)
                }
            }
            if !attrs.isEmpty { scratch.addAttributes(attrs, range: l) }
        }
        func para(_ lineHeight: CGFloat, head: CGFloat = 0, first: CGFloat? = nil, tail: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = lineHeight; p.maximumLineHeight = lineHeight
            p.headIndent = head; p.firstLineHeadIndent = first ?? head; p.tailIndent = tail
            p.paragraphSpacingBefore = before; p.paragraphSpacing = after
            return p
        }
        // Markers show where the caret is: at a selection's two ends, not across everything it covers
        // (⌘A would otherwise restyle and reveal the whole note).
        func touches(_ r: NSRange) -> Bool {
            let a = selection.location, b = NSMaxRange(selection)
            return (r.location <= a && a <= NSMaxRange(r)) || (r.location <= b && b <= NSMaxRange(r))
        }

        // Base: body text.
        let whole = NSRange(location: offset, length: lines.length)
        if mode == .raw {
            set(whole, [.font: theme.monoRaw, .foregroundColor: theme.textBody, .paragraphStyle: para(theme.rawLineHeight)])
        } else {
            set(whole, [.font: theme.body, .foregroundColor: theme.textBody, .paragraphStyle: para(theme.blankLineHeight)])
        }

        for block in document.blocks where NSIntersectionRange(block.range, lines).length > 0 || NSLocationInRange(block.range.location, lines) {
            // A block this long (a pasted 1 MB line) keeps the plain base style: styling its spans took seconds.
            guard block.range.length <= maxStyledBlockLength else { continue }
            if mode == .raw {
                styleRaw(block, set: set, theme: theme)
            } else {
                styleLive(block, text: ns, set: set, para: para, touches: touches, theme: theme, imageHeight: imageHeight)
            }
        }

        // Resolve bold/italic into fonts (after block fonts are set).
        // Collect first, then apply: mutating while enumerating, and building a font per span, was quadratic.
        var fontChanges: [(NSRange, NSFont)] = []
        var derived: [FontKey: NSFont] = [:]
        let all = NSRange(location: 0, length: scratch.length)
        scratch.enumerateAttributes(in: all) { attrs, r, _ in
            guard let raw = attrs[.featherTrait] as? UInt32, let f = attrs[.font] as? NSFont, !f.isHidden(theme) else { return }
            let key = FontKey(font: f, traits: raw)
            let styled = derived[key] ?? {
                var traits = f.fontDescriptor.symbolicTraits
                traits.insert(NSFontDescriptor.SymbolicTraits(rawValue: raw))
                let made = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: f.pointSize) ?? f
                derived[key] = made
                return made
            }()
            fontChanges.append((r, styled))
        }
        for (r, f) in fontChanges { scratch.addAttribute(.font, value: f, range: r) }
        scratch.removeAttribute(.featherTrait, range: all)

        var out: [StyleRun] = []
        scratch.enumerateAttributes(in: NSRange(location: 0, length: scratch.length)) { attrs, r, _ in
            out.append(StyleRun(range: NSRange(location: r.location + offset, length: r.length),
                                attributes: attrs.compactMapValues { $0 as? AnyHashable }))
        }
        return out
    }

    // MARK: Raw

    static func styleRaw(_ block: Block, set: (NSRange, [NSAttributedString.Key: Any]) -> Void, theme: EditorTheme) {
        let bold = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .bold)
        if case .heading = block.kind { set(block.range, [.font: bold]) }
        for inline in block.inlines where inline.kind == .strong { set(inline.range, [.font: bold]) }
        for m in block.markers + block.inlines.flatMap(\.markers) { set(m, [.foregroundColor: theme.marker]) }
        if case .listItem(_, _, let box?) = block.kind {
            switch box { case .checked(let r), .unchecked(let r): set(r, [.foregroundColor: theme.marker]) }
        }
    }

    // MARK: Live

    static func styleLive(_ block: Block, text: NSString, set: (NSRange, [NSAttributedString.Key: Any]) -> Void,
                          para: (CGFloat, CGFloat, CGFloat?, CGFloat, CGFloat, CGFloat) -> NSParagraphStyle,
                          touches: (NSRange) -> Bool, theme: EditorTheme, imageHeight: (String) -> CGFloat) {
        let hide: [NSAttributedString.Key: Any] = [.font: theme.hidden, .foregroundColor: NSColor.clear, .featherHidden: true]
        let reveal: [NSAttributedString.Key: Any] = [.font: theme.mono13, .foregroundColor: theme.marker]
        let body = para(theme.bodyLineHeight, 0, nil, 0, 0, 0)

        switch block.kind {
        case .paragraph:
            set(block.range, [.paragraphStyle: body])
        case .heading(let level):
            let lh = theme.lineHeights[level] ?? theme.bodyLineHeight
            set(block.range, [.font: theme.headingFont(level), .foregroundColor: level == 6 ? theme.textSecondary : theme.textPrimary,
                              .paragraphStyle: para(lh, 0, nil, 0, level <= 2 ? 8 : 0, 0)])
            for m in block.markers { set(m, touches(block.range) ? reveal : hide) }
        case .listItem(let ordered, let depth, let checkbox):
            let indent = theme.listIndent * CGFloat(depth + 1)
            let lines = fullLines(block.range, in: text)
            set(lines, [.paragraphStyle: para(theme.bodyLineHeight, indent, indent, 0, 0, 4)])
            // a nested item's leading spaces: the paragraph indent places it instead
            if lines.location < block.range.location {
                set(NSRange(location: lines.location, length: block.range.location - lines.location), hide)
            }
            if ordered {
                set(block.markers.first ?? block.range, [.foregroundColor: theme.textSecondary, .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)])
                set(lines, [.featherDecoration: Decoration.number])
                set(lines, [.paragraphStyle: para(theme.bodyLineHeight, indent, indent - theme.listIndent, 0, 0, 4)])
            } else if let checkbox {
                if let m = block.markers.first { set(m, hide) }
                let checked: Bool
                if case .checked = checkbox { checked = true } else { checked = false }
                eachLine(of: block.range, in: text) { line, first, _ in
                    if first { set(line, [.featherDecoration: Decoration.checkbox(checked: checked)]) }
                }
                if checked, let m = block.markers.first {
                    set(NSRange(location: NSMaxRange(m), length: NSMaxRange(block.range) - NSMaxRange(m)), [.foregroundColor: theme.textSecondary])
                }
            } else {
                if let m = block.markers.first { set(m, hide) }
                eachLine(of: block.range, in: text) { line, first, _ in
                    if first { set(line, [.featherDecoration: Decoration.bullet(depth: depth)]) }
                }
            }
        case .quote(let depth):
            let indent = theme.quoteIndent * CGFloat(depth) + 16
            set(block.range, [.font: theme.quote, .foregroundColor: theme.textPrimary])
            eachLine(of: block.range, in: text) { line, first, last in
                set(line, [.paragraphStyle: para(theme.quoteLineHeight, indent, indent, -16, first ? 16 : 0, last ? 16 : 0),
                           .featherDecoration: Decoration.quote(depth: depth, first: first, last: last)])
            }
            for m in block.markers { set(m, hide) }
        case .codeBlock(let language, let content):
            let inside = touches(block.range)
            set(block.range, [.font: theme.monoCode, .foregroundColor: theme.codeText])
            // one paragraph per line: first/last flags let the fragment round the block's corners
            var lineStart = content.location
            let end = NSMaxRange(content)
            var first = true
            while lineStart < end || (first && content.length == 0) {
                let line = text.lineRange(for: NSRange(location: min(lineStart, max(0, text.length - 1)), length: 0))
                let lineEnd = min(NSMaxRange(line), end)
                let last = lineEnd >= end
                set(NSRange(location: lineStart, length: max(0, lineEnd - lineStart)),
                    [.paragraphStyle: para(theme.codeLineHeight, theme.codePadding, nil, -theme.codePadding,
                                           first ? theme.codePadding : 0, last ? theme.codePadding : 0),
                     .featherDecoration: Decoration.code(language: language, first: first, last: last)])
                first = false
                if lineEnd <= lineStart { break }
                lineStart = lineEnd
            }
            for token in CodeHighlighter.tokens(in: text.substring(with: content), language: language) {
                let color: NSColor = switch token.kind { case .keyword: theme.syntaxKeyword; case .string: theme.syntaxString; case .comment: theme.syntaxComment }
                set(NSRange(location: content.location + token.range.location, length: token.range.length), [.foregroundColor: color])
            }
            for m in block.markers {
                if inside {
                    set(m, reveal.merging([.paragraphStyle: para(theme.codeLineHeight, theme.codePadding, nil, 0, 0, 0)]) { $1 })
                } else {
                    set(m, hide.merging([.paragraphStyle: para(0.01, 0, nil, 0, 0, 0)]) { $1 })
                }
            }
        case .thematicBreak:
            set(block.range, hide.merging([.paragraphStyle: para(theme.ruleLineHeight, 0, nil, 0, 0, 0),
                                          .featherDecoration: Decoration.rule]) { $1 })
        case .image(let alt, let url, let source):
            let height = imageHeight(url) + 8 + (alt.isEmpty ? 0 : 20)
            set(block.range, [.paragraphStyle: para(theme.bodyLineHeight, 0, nil, 0, height, 0),
                              .featherDecoration: Decoration.image(url: url, alt: alt)])
            set(source, touches(block.range) ? reveal : hide)
        case .unrendered:
            set(block.range, [.font: theme.mono13, .backgroundColor: theme.unrenderedBackground, .paragraphStyle: body])
        }

        guard case .unrendered = block.kind else {
            if case .codeBlock = block.kind { return }
            styleInlines(block, set: set, touches: touches, hide: hide, reveal: reveal, theme: theme)
            return
        }
    }

    static func styleInlines(_ block: Block, set: (NSRange, [NSAttributedString.Key: Any]) -> Void, touches: (NSRange) -> Bool,
                             hide: [NSAttributedString.Key: Any], reveal: [NSAttributedString.Key: Any], theme: EditorTheme) {
        // Strong and emphasis change the font's traits; apply them after the block font, innermost last.
        for inline in block.inlines.sorted(by: { $0.range.length > $1.range.length }) {
            let content = NSRange(location: NSMaxRange(inline.markers.first ?? NSRange(location: inline.range.location, length: 0)),
                                  length: max(0, (inline.markers.last?.location ?? NSMaxRange(inline.range)) - NSMaxRange(inline.markers.first ?? NSRange(location: inline.range.location, length: 0))))
            switch inline.kind {
            case .strong: set(content, [.featherTrait: NSFontDescriptor.SymbolicTraits.bold.rawValue])
            case .emphasis: set(content, [.featherTrait: NSFontDescriptor.SymbolicTraits.italic.rawValue])
            case .strikethrough: set(content, [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
            case .code: set(content, [.font: theme.mono13, .backgroundColor: theme.inlineCodeBackground])
            case .link(let url) where url.lowercased().hasPrefix("feather://attachment/"):
                // an attachment chip: the hidden "[" makes room for the type badge
                set(content, [.foregroundColor: theme.textPrimary, .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                              .featherLink: url, .featherChip: url])
                if let open = inline.markers.first, !touches(inline.range) { set(open, [.kern: 40]) }
            case .link(let url):
                set(content, [.foregroundColor: theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .underlineColor: theme.accent.withAlphaComponent(0.5), .featherLink: url])
            case .html: set(inline.range, [.font: theme.mono13, .backgroundColor: theme.unrenderedBackground])
            }
        }
        for inline in block.inlines where inline.kind != .html {
            for m in inline.markers {
                var attrs = touches(inline.range) ? reveal : hide
                if case .link(let url) = inline.kind, url.lowercased().hasPrefix("feather://attachment/"), m == inline.markers.first, !touches(inline.range) {
                    attrs[.kern] = 40
                }
                set(m, attrs)
            }
        }
    }
}

extension NSAttributedString.Key {
    /// Internal: symbolic traits to merge into the font (resolved before runs are returned).
    static let featherTrait = NSAttributedString.Key("featherTrait")
}

extension NSFont {
    func isHidden(_ theme: EditorTheme) -> Bool { pointSize < 0.1 }
}

/// Calls `body` for each source line of `range`, with first/last flags.
/// The full lines covering `range`.
func fullLines(_ range: NSRange, in text: NSString) -> NSRange {
    guard text.length > 0 else { return range }
    let start = min(range.location, text.length)
    return text.lineRange(for: NSRange(location: start, length: max(0, min(range.length, text.length - start))))
}

/// Calls `body` with each full line `range` touches (from the line start, so leading indentation and
/// container markers carry the paragraph attributes: TextKit reads them from a paragraph's first character).
func eachLine(of range: NSRange, in text: NSString, _ body: (NSRange, Bool, Bool) -> Void) {
    var start = text.length == 0 ? 0 : text.lineRange(for: NSRange(location: min(range.location, text.length - 1), length: 0)).location
    let end = NSMaxRange(range)
    var first = true
    repeat {
        let line = text.lineRange(for: NSRange(location: min(start, max(0, text.length - 1)), length: 0))
        let lineEnd = min(NSMaxRange(line), end)
        body(NSRange(location: start, length: max(0, lineEnd - start)), first, lineEnd >= end)
        first = false
        if lineEnd <= start { break }
        start = lineEnd
    } while start < end
}

/// Cache key for a font with extra symbolic traits (bold, italic) added.
private struct FontKey: Hashable {
    let font: NSFont
    let traits: UInt32
}

import Foundation
import Testing
@testable import FeatherEditor
import Markdown

func sub(_ text: String, _ r: NSRange) -> String { (text as NSString).substring(with: r) }

func blocks(_ text: String) -> [Block] { MarkdownParser.parse(text).blocks }

@Test func headingsLevels1To6() {
    let t = "# A\n\n###### F\n\n#NoSpace"
    let b = blocks(t)
    #expect(b.count == 3)
    #expect(b[0].kind == .heading(level: 1) && b[0].markers.map { sub(t, $0) } == ["# "])
    #expect(b[1].kind == .heading(level: 6))
    #expect(b[2].kind == .paragraph)
}

@Test func emphasisVariants() {
    for (t, kind, markers) in [("**b**", InlineKind.strong, ["**", "**"]), ("__b__", .strong, ["__", "__"]),
                               ("*i*", .emphasis, ["*", "*"]), ("_i_", .emphasis, ["_", "_"]),
                               ("~~s~~", .strikethrough, ["~~", "~~"]), ("`c`", .code, ["`", "`"])] {
        let inl = blocks(t)[0].inlines
        #expect(inl.count == 1, "\(t)")
        #expect(inl.first?.kind == kind && inl.first.map { $0.markers.map { sub(t, $0) } } == markers, "\(t)")
        #expect(inl.first.map { sub(t, $0.range) } == t)
    }
    #expect(blocks("**unclosed")[0].inlines.isEmpty)
}

@Test func nestedEmphasis() {
    let t = "***bi***"
    let kinds = Set(blocks(t)[0].inlines.map(\.kind))
    #expect(kinds == [.strong, .emphasis])
    let all = blocks(t)[0].inlines.flatMap(\.markers).map { sub(t, $0) }.joined()
    #expect(all == "******")
}

@Test func linksAndImages() {
    let t = "see [t](u) ok"
    let link = blocks(t)[0].inlines.first
    #expect(link?.kind == .link(url: "u"))
    #expect(link?.markers.map { sub(t, $0) } == ["[", "](u)"])
    let img = "![a](feather://attachment/01JC8ZQ6V4N1XG2H3K5M7P9R0T)"
    let b = blocks(img)[0]
    #expect(b.kind == .image(alt: "a", url: "feather://attachment/01JC8ZQ6V4N1XG2H3K5M7P9R0T", sourceRange: NSRange(location: 0, length: (img as NSString).length)))
    #expect(blocks("text ![a](x.png)")[0].kind == .paragraph)
}

@Test func listsAndTasks() {
    let t = "- a\n* b\n\n+ c\n\n1. d\n   - e\n\n- [ ] t\n- [x] u"
    let items = blocks(t).filter { if case .listItem = $0.kind { true } else { false } }
    #expect(items.count == 7)
    #expect(items[0].kind == .listItem(ordered: false, depth: 0, checkbox: nil) && items[0].markers.map { sub(t, $0) } == ["- "])
    #expect(items[3].kind == .listItem(ordered: true, depth: 0, checkbox: nil) && items[3].markers.map { sub(t, $0) } == ["1. "])
    #expect(items[4].kind == .listItem(ordered: false, depth: 1, checkbox: nil))
    guard case .listItem(_, _, .unchecked(let r1)) = items[5].kind, case .listItem(_, _, .checked(let r2)) = items[6].kind else {
        Issue.record("checkboxes"); return
    }
    #expect(sub(t, r1) == "[ ]" && sub(t, r2) == "[x]")
    #expect(items[5].markers.map { sub(t, $0) } == ["- [ ] "])
}

@Test func quotesNested() {
    let t = "> a\n>\n> > b"
    let q = blocks(t).compactMap { b -> Int? in if case .quote(let d) = b.kind { d } else { nil } }
    #expect(q == [1, 2])
}

@Test func fencesWithLanguage() {
    let t = "```swift\nlet x = 1\n```\n\n~~~\nraw\n~~~"
    let b = blocks(t)
    guard case .codeBlock(let lang, let content) = b[0].kind else { Issue.record("code"); return }
    #expect(lang == "swift" && sub(t, content) == "let x = 1\n")
    #expect(b[0].markers.map { sub(t, $0) } == ["```swift\n", "```"])
    guard case .codeBlock(let lang2, _) = b[1].kind else { Issue.record("tilde"); return }
    #expect(lang2 == nil)
    let open = "```\nnever closed\n\n# not a heading"
    #expect(blocks(open).count == 1)
}

@Test func thematicBreaks() {
    for t in ["---", "***", "___"] { #expect(blocks("a\n\n" + t)[1].kind == .thematicBreak, "\(t)") }
    #expect(blocks("Title\n---")[0].kind == .heading(level: 2))
}

@Test func tablesAndHTMLAreUnrendered() {
    #expect(blocks("| a | b |\n|---|---|\n| 1 | 2 |")[0].kind == .unrendered)
    #expect(blocks("<div>\nx\n</div>")[0].kind == .unrendered)
    #expect(blocks("a <b>c</b>")[0].inlines.contains { $0.kind == .html })
}

@Test func rangesAreUTF16() {
    let t = "😀 **é**\r\n\r\n# Cafe\u{301}"
    let b = blocks(t)
    #expect(b[0].inlines.first.map { sub(t, $0.range) } == "**é**")
    #expect(sub(t, b[1].range).hasPrefix("# Cafe\u{301}"))
    #expect(b[1].kind == .heading(level: 1))
}

@Test func everyInlineMarkerIsARealDelimiter() {
    let lazy = "- item\nlazy `code` and **bold**\n\n> quote\nlazy *em* line"
    for (_, text) in Corpus.all() + [("lazy", lazy)] {
        for b in MarkdownParser.parse(text).blocks {
            for i in b.inlines {
                #expect(NSMaxRange(i.range) <= NSMaxRange(b.range) && i.range.location >= b.range.location)
                for m in i.markers {
                    let s = sub(text, m)
                    #expect(s.allSatisfy { "*_~`[]!(".contains($0) } || s.hasPrefix("]"), "\(s.debugDescription) in \(text.prefix(30))")
                }
            }
        }
    }
}

/// A pasted 1 MB line with thousands of inline spans must parse in linear time.
@Suite struct ParserScalingTests {
    func parseTime(spans: Int) -> Double {
        let text = String(repeating: "word **b** ", count: spans)
        let d = ContinuousClock().measure { _ = MarkdownParser.parse(text) }
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test func manyInlineSpansParseInLinearTime() {
        _ = parseTime(spans: 200)
        let small = parseTime(spans: 1_000)
        let large = parseTime(spans: 4_000)
        perf("PERF parser 1k spans \(small * 1000) ms, 4k spans \(large * 1000) ms")
        #expect(large < small * 8, "4× the spans cost \(large / small)×; quadratic would be about 16×")
    }
}

@Suite struct LocationMapTests {
    /// Every (line, column) on long non-ASCII lines maps to the same UTF-16 offset as a walk from the line start.
    @Test func checkpointsMatchAWalkFromTheLineStart() {
        let line = String(repeating: "é **b** 😀 naïve ", count: 40)
        let text = line + "\r\n" + line + "\n\n" + String(repeating: "x", count: 100) + "日本"
        let map = LocationMap(text)
        let bytes = Array(text.utf8)
        var lineNo = 1, col = 1, u16 = 0, i = 0
        var mismatches = 0
        while i <= bytes.count {
            if map.offset(Markdown.SourceLocation(line: lineNo, column: col, source: nil)) != u16 { mismatches += 1 }
            guard i < bytes.count else { break }
            let b = bytes[i]
            let width = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
            u16 += width == 4 ? 2 : 1
            i += width; col += width
            if b == 0x0A || (b == 0x0D && (i >= bytes.count || bytes[i] != 0x0A)) { lineNo += 1; col = 1 }
        }
        #expect(mismatches == 0)
    }
}

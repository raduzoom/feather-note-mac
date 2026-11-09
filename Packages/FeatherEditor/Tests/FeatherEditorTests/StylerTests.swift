import AppKit
import Testing
@testable import FeatherEditor

/// Styles `text` with the caret at `caret` and returns the storage, for reading attributes back.
@MainActor func styled(_ text: String, caret: Int? = nil, mode: EditorMode = .live) -> NSTextStorage {
    let storage = NSTextStorage(string: text)
    let doc = MarkdownParser.parse(text)
    let whole = NSRange(location: 0, length: (text as NSString).length)
    let sel = NSRange(location: caret ?? (text as NSString).length + 1, length: 0)
    for run in MarkdownStyler.runs(text: text, document: doc, selection: sel, mode: mode, theme: .standard, in: whole) {
        storage.setAttributes(run.attributes.nsAttributes, range: run.range)
    }
    return storage
}

@MainActor func isHidden(_ s: NSTextStorage, _ i: Int) -> Bool { s.attribute(.featherHidden, at: i, effectiveRange: nil) as? Bool == true }
@MainActor func font(_ s: NSTextStorage, _ i: Int) -> NSFont { s.attribute(.font, at: i, effectiveRange: nil) as! NSFont }
@MainActor func decoration(_ s: NSTextStorage, _ i: Int) -> Decoration? { s.attribute(.featherDecoration, at: i, effectiveRange: nil) as? Decoration }

@MainActor @Suite struct StylerTests {
    let theme = EditorTheme.standard

    @Test func headingStylesPerSpec() {
        let t = "# One\n\n## Two\n\n### Three\n\n#### Four\n\n###### Six"
        let s = styled(t)
        let ns = t as NSString
        func at(_ word: String) -> Int { ns.range(of: word).location }
        #expect(font(s, at("One")).pointSize == 30)
        #expect(font(s, at("Two")).pointSize == 22)
        #expect(font(s, at("Three")).pointSize == 18)
        #expect(font(s, at("Four")).pointSize == 16 && font(s, at("Four")).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(font(s, at("One")).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(s.attribute(.foregroundColor, at: at("Six"), effectiveRange: nil) as? NSColor == theme.textSecondary)
        let p = s.attribute(.paragraphStyle, at: at("One"), effectiveRange: nil) as! NSParagraphStyle
        #expect(p.minimumLineHeight == 36 && p.maximumLineHeight == 36)
    }

    @Test func markersHiddenAwayFromCaret() {
        let cases: [(String, [Int], Int)] = [("a **b** c", [2, 3, 5, 6], 4), ("a _b_ c", [2, 4], 3), ("a `b` c", [2, 4], 3),
                                            ("a [b](u) c", [2, 4, 5, 6, 7], 3), ("# H", [0, 1], 2)]
        for (t, hidden, visible) in cases {
            let s = styled(t, caret: nil)
            for i in hidden { #expect(isHidden(s, i), "\(t) @\(i)") }
            #expect(!isHidden(s, visible), "\(t) visible @\(visible)")
        }
    }

    @Test func markersShownAtCaret() {
        let t = "a **bold** c"
        for caret in [2, 4, 10] {   // at the first marker, inside, just past the end
            let s = styled(t, caret: caret)
            #expect(!isHidden(s, 2) && !isHidden(s, 8), "caret \(caret)")
            #expect(font(s, 2).fontDescriptor.symbolicTraits.contains(.monoSpace))
            #expect(font(s, 2).pointSize == 13)
            #expect(s.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == theme.marker)
        }
        #expect(isHidden(styled(t, caret: 11), 2))
        let h = styled("# Head\n\nx", caret: 3)
        #expect(!isHidden(h, 0))
    }

    @Test func listMarkersAlwaysDecorated() {
        let t = "- one\n- two"
        for caret in [0, 3, 8] {
            let s = styled(t, caret: caret)
            #expect(isHidden(s, 0) && isHidden(s, 1))
            #expect(decoration(s, 2) == .bullet(depth: 0))
        }
        let n = styled("1. first")
        #expect(!isHidden(n, 0) && decoration(n, 3) == .number)
    }

    @Test func checkedItemTextIsSecondary() {
        let s = styled("- [x] done\n- [ ] todo")
        #expect(decoration(s, 6) == .checkbox(checked: true))
        #expect(s.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor == theme.textSecondary)
        #expect(decoration(s, 17) == .checkbox(checked: false))
        #expect((0..<6).allSatisfy { isHidden(s, $0) })
    }

    @Test func rawModeIsMonoWithMarkerColour() {
        let t = "# H\n\na **b** c"
        let s = styled(t, mode: .raw)
        for i in 0..<(t as NSString).length {
            #expect(!isHidden(s, i))
            #expect(font(s, i).fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
        #expect(s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == theme.marker)
        #expect(font(s, 2).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(font(s, 7).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(decoration(s, 7) == nil)
    }

    @Test func unrenderedIsMonoOnFaintBackground() {
        let s = styled("| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(font(s, 2).fontDescriptor.symbolicTraits.contains(.monoSpace) && font(s, 2).pointSize == 13)
        #expect(s.attribute(.backgroundColor, at: 2, effectiveRange: nil) as? NSColor == theme.unrenderedBackground)
        #expect(!isHidden(s, 0))
    }

    @Test func codeBlockFencesCollapseAwayFromCaret() {
        let t = "```swift\nlet x = \"s\" // c\n```"
        let s = styled(t)
        #expect(isHidden(s, 0) && isHidden(s, (t as NSString).length - 1))
        let content = (t as NSString).range(of: "let").location
        #expect(decoration(s, content) == .code(language: "swift", first: true, last: true))
        #expect(font(s, content).pointSize == 12.5)
        let inside = styled(t, caret: content + 1)
        #expect(!isHidden(inside, 0))
    }

    @Test func codeHighlighter() {
        let line = "let s = \"str\" // note"
        let tokens = CodeHighlighter.tokens(in: line, language: "swift")
        func kind(_ word: String) -> CodeHighlighter.Kind? {
            let r = (line as NSString).range(of: word)
            return tokens.first { NSLocationInRange(r.location, $0.range) }?.kind
        }
        #expect(kind("let") == .keyword && kind("str") == .string && kind("note") == .comment && kind("s =") == nil)
        #expect(CodeHighlighter.tokens(in: "# c", language: "swift").isEmpty)
        #expect(CodeHighlighter.tokens(in: "# c", language: "python").first?.kind == .comment)
        #expect(CodeHighlighter.tokens(in: "a /* b */ c", language: nil).first?.kind == .comment)
    }

    @Test func corpusRoundTripsByteIdentical() {
        for (name, text) in Corpus.all() {
            for caret in [0, (text as NSString).length / 2, (text as NSString).length] {
                for mode in [EditorMode.live, .raw] {
                    let s = styled(text, caret: caret, mode: mode)
                    #expect(Array(s.string.utf8) == Array(text.utf8), "\(name) caret \(caret) \(mode)")
                }
            }
        }
    }
}

/// One paragraph with thousands of bold spans (a pasted 1 MB line) must style in linear time.
@MainActor @Suite struct StylerScalingTests {
    func styleTime(spans: Int) -> Double {
        let text = String(repeating: "word **b** ", count: spans)
        let doc = MarkdownParser.parse(text)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let d = ContinuousClock().measure {
            _ = MarkdownStyler.runs(text: text, document: doc, selection: NSRange(location: 2, length: 0), mode: .live, theme: .standard, in: whole)
        }
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test func manyBoldSpansStyleInLinearTime() {
        _ = styleTime(spans: 500)   // warm up fonts and caches
        // 5,600 spans is 62 KB: still under maxStyledBlockLength, so the spans really are styled
        let small = styleTime(spans: 1_400)
        let large = styleTime(spans: 5_600)
        perf("PERF styler 1.4k spans \(small * 1000) ms, 5.6k spans \(large * 1000) ms")
        #expect(large < small * 8, "4× the spans cost \(large / small)×; quadratic would be about 16×")
    }
}

/// A paragraph too long to style live (a pasted 1 MB line) is shown as plain Markdown instead of locking up.
@MainActor @Suite struct OversizedBlockTests {
    @Test func oversizedParagraphShowsPlainMarkdown() {
        let text = String(repeating: "word **b** ", count: 7_000)   // 77 KB
        let s = styled(text, caret: 0)
        #expect(!isHidden(s, 5))   // the ** stays visible
        #expect(!font(s, 7).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(font(s, 7) == EditorTheme.standard.body)
    }

    @Test func longParagraphUnderTheLimitStaysLive() {
        let text = String(repeating: "word **b** ", count: 5_000)   // 55 KB
        let s = styled(text, caret: 0)
        #expect(isHidden(s, 5))
        #expect(font(s, 7).fontDescriptor.symbolicTraits.contains(.bold))
    }
}

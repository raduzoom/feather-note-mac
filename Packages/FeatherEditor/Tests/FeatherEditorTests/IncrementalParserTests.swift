import Foundation
import Testing
@testable import FeatherEditor

private let alphabet: [String] = ["<!--", "-->", "<pre>", "a", "b", " ", "\n", "\n\n", "*", "**", "_", "`", "```", "~", "#", "# ", "- ", "1. ", "> ", "[", "]", "(", ")", "- [ ] ", "---", "  ", "\t", "é", "😀", "\r\n", "|", "<b>", "!["]

@Test func matchesFullParseAfterRandomEdits() {
    var rng = SplitMix64(state: 1)
    for (name, original) in Corpus.all() {
        let parser = IncrementalParser(text: original)
        var text = original as NSString
        for step in 0..<200 {
            let length = text.length
            let start = Int.random(in: 0...length, using: &rng)
            let deleteLength = Bool.random(using: &rng) ? 0 : Int.random(in: 0...min(6, length - start), using: &rng)
            let insert = Bool.random(using: &rng) || deleteLength == 0 ? alphabet.randomElement(using: &rng)! : ""
            // keep surrogate pairs and CRLF intact, like a real text view does
            let safe = text.rangeOfComposedCharacterSequences(for: NSRange(location: min(start, max(0, length - 1)), length: length == 0 ? 0 : max(deleteLength, 0)))
            let edit = length == 0 ? NSRange(location: 0, length: 0) : (deleteLength == 0 ? NSRange(location: start == length ? length : safe.location, length: 0) : safe)
            let newText = text.replacingCharacters(in: edit, with: insert) as NSString
            _ = parser.apply(edit: edit, replacementLength: (insert as NSString).length, newText: newText as String)
            let full = MarkdownParser.parse(newText as String)
            if parser.document != full {
                let a = parser.document.blocks, b = full.blocks
                let i = Array(zip(a, b)).firstIndex { $0.0 != $0.1 } ?? min(a.count, b.count)
                Issue.record("\(name) step \(step): edit \(edit) insert \(insert.debugDescription)\ntext: \((newText as String).debugDescription)\ncounts \(a.count) vs \(b.count); first diff at \(i)\nincr: \(i < a.count ? String(describing: a[i]) : "-")\nfull: \(i < b.count ? String(describing: b[i]) : "-")")
                return
            }
            text = newText
        }
    }
}

@Test func openingAFenceReparsesToEnd() {
    let t = "a\n\n# H\n\n- item\n"
    let p = IncrementalParser(text: t)
    let n = "```\n" + t
    let changed = p.apply(edit: NSRange(location: 0, length: 0), replacementLength: 4, newText: n)
    #expect(p.document == MarkdownParser.parse(n))
    #expect(NSMaxRange(changed) == (n as NSString).length)
}

@Test func closingAFenceRestores() {
    let t = "```\ncode\n\n# H\n"
    let p = IncrementalParser(text: t)
    let n = "```\ncode\n```\n\n# H\n"
    _ = p.apply(edit: NSRange(location: 9, length: 0), replacementLength: 4, newText: n)
    #expect(p.document == MarkdownParser.parse(n))
    #expect(p.document.blocks.last?.kind == .heading(level: 1))
}

@Test func returnedRangeCoversChangedSpans() {
    let t = "one\n\nsome *word here\n\nthree"
    let p = IncrementalParser(text: t)
    let n = "one\n\nsome *word* here\n\nthree"
    let changed = p.apply(edit: NSRange(location: 15, length: 0), replacementLength: 1, newText: n)
    let para = p.document.blocks[1].range
    #expect(NSIntersectionRange(changed, para) == para)
    #expect(p.document.blocks[1].inlines.first?.kind == .emphasis)
}

/// The running count of link reference definitions always equals a full recount, so keystrokes need not scan the note.
@Test func referenceDefinitionCountTracksEdits() {
    let pieces = ["[a]: u", "[b]:", "]:", "[", "]", ":", "\n", "\r", "\r\n", " ", "    ", "x", "é"]
    var rng = SplitMix64(state: 5)
    var text = "Intro\n\n[ref]: https://example.com\n\nText [ref] here.\r\n[x]: y" as NSString
    let parser = IncrementalParser(text: text as String)
    for step in 0..<3_000 {
        let start = Int.random(in: 0...text.length, using: &rng)
        let len = Int.random(in: 0...min(4, text.length - start), using: &rng)
        let edit = text.rangeOfComposedCharacterSequences(for: NSRange(location: min(start, max(0, text.length - 1)), length: text.length == 0 ? 0 : len))
        let e = len == 0 ? NSRange(location: start, length: 0) : edit
        let insert = Bool.random(using: &rng) ? pieces.randomElement(using: &rng)! : ""
        text = text.replacingCharacters(in: e, with: insert) as NSString
        parser.apply(edit: e, replacementLength: (insert as NSString).length, newText: text as String)
        let expected = IncrementalParser.countReferenceDefinitions(text)
        if parser.referenceDefinitionCount != expected {
            Issue.record("step \(step): count \(parser.referenceDefinitionCount), expected \(expected), text \((text as String).debugDescription)")
            return
        }
    }
}

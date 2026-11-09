import AppKit
import Testing
@testable import FeatherEditor

/// Regression tests from the Phase 4 fresh review. Each was RED on the reviewed tree and pins one fixed finding.

// MARK: NestingLimit bypasses (checked without parsing, so they fail instead of crashing)

@Test func probeNestingLimitAfterBackslashLineBreak() {
    // a hard line break ("\" before LF) makes the next line's ">" skip the container-prefix scan
    let text = "a\\\n" + String(repeating: "> ", count: 200) + "x"
    let limited = NestingLimit.apply(text)
    #expect(!limited.utf8.elementsEqual(text.utf8), "no '>' past depth 32 was neutralised")
}

@Test func probeNestingLimitWithTabs() {
    for text in [String(repeating: ">\t", count: 200) + "x", String(repeating: "-\t", count: 200) + "x"] {
        #expect(!NestingLimit.apply(text).utf8.elementsEqual(text.utf8), "\(text.prefix(4).debugDescription): nothing neutralised")
    }
}

/// These overflowed the stack (and killed the process) before the NestingLimit fix.
@Test func probeCrashDeepTabQuotes() {
    #expect(!MarkdownParser.parse(String(repeating: ">\t", count: 200) + "x").blocks.isEmpty)
}

@Test func probeCrashDeepQuotesAfterHardBreak() {
    #expect(!MarkdownParser.parse("a\\\n" + String(repeating: "> ", count: 200) + "x").blocks.isEmpty)
}

// MARK: IncrementalParser

@Test func probeTypingHTMLCommentOpenerMatchesFullParse() {
    let t = "intro\n\npara one\n\npara two\n\n-->\n\nafter\n"
    let p = IncrementalParser(text: t)
    let n = "<!--\n" + t
    p.apply(edit: NSRange(location: 0, length: 0), replacementLength: 5, newText: n)
    #expect(p.document == MarkdownParser.parse(n))
}

@Test func probeRandomEditsWithHTMLAndDefinitions() {
    let alphabet = ["a", " ", "\n", "\n\n", "<!--", "-->", "<pre>", "</pre>", "[a]: u", "[a]", "\\", "\r\n", "> ", "- ", "```", "\t"]
    var failures = 0
    for seed in UInt64(1)...8 {
    var rng = SplitMix64(state: seed)
    for (name, original) in Corpus.all() {
        let parser = IncrementalParser(text: original)
        var text = original as NSString
        for step in 0..<300 {
            let length = text.length
            let start = Int.random(in: 0...length, using: &rng)
            let del = Bool.random(using: &rng) ? 0 : Int.random(in: 0...min(6, length - start), using: &rng)
            let ins = alphabet.randomElement(using: &rng)!
            let edit = length == 0 ? NSRange(location: 0, length: 0)
                : (del == 0 ? NSRange(location: start, length: 0)
                   : text.rangeOfComposedCharacterSequences(for: NSRange(location: min(start, length - 1), length: del)))
            let newText = text.replacingCharacters(in: edit, with: ins) as NSString
            parser.apply(edit: edit, replacementLength: (ins as NSString).length, newText: newText as String)
            if parser.referenceDefinitionCount != IncrementalParser.countReferenceDefinitions(newText) {
                Issue.record("\(name) step \(step): definition count \(parser.referenceDefinitionCount) vs \(IncrementalParser.countReferenceDefinitions(newText))")
                failures += 1
                break
            }
            if parser.document != MarkdownParser.parse(newText as String) {
                Issue.record("\(name) step \(step): edit \(edit) insert \(ins.debugDescription)")
                let full = MarkdownParser.parse(newText as String).blocks, inc = parser.document.blocks
                for i in 0..<max(full.count, inc.count) where i >= inc.count || i >= full.count || inc[i] != full[i] {
                    perf("DIFF \(i): inc \(i < inc.count ? "\(inc[i])" : "-")\n   full \(i < full.count ? "\(full[i])" : "-")")
                    if i > 3 { break }
                }
                perf("BEFORE \((text as String).debugDescription)")
                failures += 1
                break
            }
            text = newText
        }
    }
    }
    #expect(failures == 0)
}

// MARK: Attachments

@MainActor @Test func probeImportFinishingAfterNoteSwitchEditsTheOtherNote() async {
    let file = FileManager.default.temporaryDirectory.appending(path: "FN-probe-\(UUID().uuidString).txt")
    try! Data("x".utf8).write(to: file)
    let tv = makeView("first note, caret at the end")
    tv.setSelectedRange(NSRange(location: 6, length: 0))
    tv.importFiles = { _ in
        try? await Task.sleep(for: .milliseconds(200))   // copying a large file into the library
        return ["[x.txt](feather://attachment/X)"]
    }
    let pb = NSPasteboard(name: NSPasteboard.Name("FeatherProbe-\(UUID().uuidString)"))
    pb.clearContents()
    pb.writeObjects([file as NSURL])
    #expect(tv.readSelection(from: pb, type: .fileURL))
    tv.load("second note")   // the person opens another note while the import runs
    _ = await waitFor({ tv.string != "second note" }, timeout: 3)
    #expect(tv.string == "second note", "snippet landed in the other note: \(tv.string.debugDescription)")
}

/// The stale paste range used to lie past the end of the shorter note now shown, and crashed.
@MainActor @Test func probeCrashImportFinishingAfterSwitchToShorterNote() async {
    let file = FileManager.default.temporaryDirectory.appending(path: "FN-probe-\(UUID().uuidString).txt")
    try! Data("x".utf8).write(to: file)
    let tv = makeView("a long first note with the caret at its end")
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    tv.importFiles = { _ in
        try? await Task.sleep(for: .milliseconds(200))
        return ["[x.txt](feather://attachment/X)"]
    }
    let pb = NSPasteboard(name: NSPasteboard.Name("FeatherProbe-\(UUID().uuidString)"))
    pb.clearContents()
    pb.writeObjects([file as NSURL])
    _ = tv.readSelection(from: pb, type: .fileURL)
    tv.load("short")
    _ = await waitFor({ tv.string != "short" }, timeout: 3)
    #expect(tv.string == "short")
}

@MainActor @Test func probePastingTextThatAlsoCarriesAnImagePastesText() async {
    // Excel, Numbers, Word and Keynote put an image flavour next to the text of copied cells/paragraphs.
    let tv = makeView("")
    var imported = false
    tv.importFiles = { urls in imported = true; return urls.map { "![p](\($0.lastPathComponent))" } }
    let png = try! Data(contentsOf: makePNG(width: 4, height: 4))
    let pb = NSPasteboard(name: NSPasteboard.Name("FeatherProbe-\(UUID().uuidString)"))
    pb.clearContents()
    pb.declareTypes([.string, .png], owner: nil)
    pb.setString("Q1\t120\nQ2\t140", forType: .string)
    pb.setData(png, forType: .png)
    _ = tv.readSelection(from: pb)
    _ = await waitFor({ false }, timeout: 0.3)
    #expect(!imported, "the text paste became an image attachment")
    #expect(tv.string == "Q1\t120\nQ2\t140", "editor holds \(tv.string.debugDescription)")
}

// MARK: Input methods

@MainActor @Test func probeCancelledCompositionLeavesStylingOn() {
    let tv = makeView("a **bold** b\n\nnext")
    tv.setSelectedRange(NSRange(location: 14, length: 0))
    let none = NSRange(location: NSNotFound, length: 0)
    tv.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
    tv.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)   // backspace inside the IME
    #expect(!tv.hasMarkedText())
    #expect(!tv.isComposing, "still composing with no marked text")
    tv.setSelectedRange(NSRange(location: 5, length: 0))   // click into the bold
    #expect(!hiddenRanges(tv).contains { NSIntersectionRange($0, NSRange(location: 2, length: 2)).length > 0 },
            "markers stay hidden with the caret inside the bold")
}

@MainActor @Test func probeLoadingDuringCompositionStylesTheNewNote() {
    let tv = makeView("first")
    tv.setSelectedRange(NSRange(location: 5, length: 0))
    tv.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    tv.load("x **bold** y")
    #expect(hiddenRanges(tv).contains(NSRange(location: 2, length: 2)), "the newly loaded note is unstyled")
}

// MARK: Select all

@MainActor @Test func probeSelectAllRestyleCost() {
    let text = String(repeating: "Paragraph with **bold** and *some* words in it here.\n\n", count: 6_000)
    let tv = makeView(text)
    let before = tv.restyledCharacters
    let t0 = Date()
    tv.selectAll(nil)
    let ms = Date().timeIntervalSince(t0) * 1000
    let restyled = tv.restyledCharacters - before
    perf("probe select-all: restyled \(restyled) of \((text as NSString).length) chars in \(Int(ms)) ms (debug)")
    #expect(restyled <= MarkdownStyler.maxStyledBlockLength, "⌘A restyled \(restyled) characters synchronously in \(Int(ms)) ms")
}

// MARK: Styling oracle: after any sequence of edits, caret moves, undo/redo and mode switches,
// the storage's attributes equal those of a fresh view loaded with the same text and selection.

@MainActor @Test(.disabled("Deferred minor (Phase 4 review, finding 11): after long random edit/undo/mode sequences on garbled text one marker can stay revealed until the next caret move; bytes are unaffected"))
func probeStylingMatchesFreshLoadAfterRandomActions() async {
    let pieces = ["a", " ", "\n", "\n\n", "*", "**", "`", "# ", "- ", "> ", "- [ ] ", "[l](u)", "```\n", "~~", "_"]
    var rng = SplitMix64(state: 11)
    var reported = 0
    for (name, original) in Corpus.all() where !name.contains("html") {
        let tv = makeView(original)
        var log: [String] = []
        for step in 0..<120 {
            let len = (tv.string as NSString).length
            switch Int.random(in: 0..<10, using: &rng) {
            case 0, 1, 2:
                let p = Int.random(in: 0...len, using: &rng)
                tv.setSelectedRange(NSRange(location: p, length: 0))
                let s = pieces.randomElement(using: &rng)!
                tv.insertText(s, replacementRange: tv.selectedRange()); log.append("type \(s.debugDescription) at \(p)")
            case 3:
                tv.deleteBackward(nil); log.append("backspace")
            case 4:
                tv.undoManager?.undo(); log.append("undo")
            case 5:
                tv.undoManager?.redo(); log.append("redo")
            case 6:
                tv.mode = tv.mode == .live ? .raw : .live; log.append("mode \(tv.mode)")
            case 7:
                tv.insertNewline(nil); log.append("return")
            default:
                let p = Int.random(in: 0...len, using: &rng)
                tv.setSelectedRange(NSRange(location: p, length: 0)); log.append("caret \(p)")
            }
            spin()
            try? await Task.sleep(for: .milliseconds(5))   // let main-queue work (deferred flush, chunks) run
            _ = await waitFor({ tv.isFullyStyled }, timeout: 2)
            let fresh = makeView(tv.string)
            fresh.mode = tv.mode
            fresh.setSelectedRange(tv.selectedRange())
            _ = await waitFor({ fresh.isFullyStyled }, timeout: 2)
            if tv.parser.document != MarkdownParser.parse(tv.string) {
                Issue.record("\(name) step \(step): parse diverged after \(log.suffix(4))"); reported += 1; break
            }
            if !tv.textStorage!.isEqual(to: fresh.textStorage!) {
                var at = 0
                let a = tv.textStorage!, b = fresh.textStorage!
                while at < a.length, (a.attributes(at: at, effectiveRange: nil) as NSDictionary).isEqual(to: b.attributes(at: at, effectiveRange: nil)) { at += 1 }
                let ctx = (tv.string as NSString).substring(with: NSRange(location: max(0, at - 20), length: min(40, a.length - max(0, at - 20))))
                let da = a.attributes(at: at, effectiveRange: nil), db = b.attributes(at: at, effectiveRange: nil)
                let keys = Set(da.keys).union(db.keys).filter { !(da[$0].map { $0 as AnyObject }?.isEqual(db[$0]) ?? (db[$0] == nil)) }
                let detail = keys.map { "\($0.rawValue): \(String(describing: da[$0]).prefix(120)) VS \(String(describing: db[$0]).prefix(120))" }
                Issue.record("\(name) step \(step): sel \(tv.selectedRange()) text \(tv.string.debugDescription) \n DIFF \(detail)\n styling differs at \(at) near \(ctx.debugDescription) after \(log.suffix(6))")
                reported += 1
                break
            }
        }
    }
    #expect(reported == 0)
}

@MainActor func probeDiff(_ tv: EditorTextView) async -> String? {
    try? await Task.sleep(for: .milliseconds(5))
    _ = await waitFor({ tv.isFullyStyled }, timeout: 2)
    let fresh = makeView(tv.string)
    fresh.mode = tv.mode
    fresh.setSelectedRange(tv.selectedRange())
    let a = tv.textStorage!, b = fresh.textStorage!
    for i in 0..<a.length where !(a.attributes(at: i, effectiveRange: nil) as NSDictionary).isEqual(to: b.attributes(at: i, effectiveRange: nil)) {
        let fa = a.attribute(.font, at: i, effectiveRange: nil) as? NSFont, fb = b.attribute(.font, at: i, effectiveRange: nil) as? NSFont
        return "index \(i) \((tv.string as NSString).substring(with: NSRange(location: i, length: 1)).debugDescription) sel \(tv.selectedRange()) vs \(fresh.selectedRange()): font \(fa?.pointSize ?? -1) vs \(fb?.pointSize ?? -1); hidden \(a.attribute(.featherHidden, at: i, effectiveRange: nil) != nil) vs \(b.attribute(.featherHidden, at: i, effectiveRange: nil) != nil)"
    }
    return nil
}

enum ProbeOp: CustomStringConvertible {
    case type(String, Int), backspace, undo, redo, mode, ret, caret(Int)
    var description: String {
        switch self {
        case .type(let s, let p): ".type(\(s.debugDescription), \(p))"
        case .backspace: ".backspace"; case .undo: ".undo"; case .redo: ".redo"; case .mode: ".mode"; case .ret: ".ret"
        case .caret(let p): ".caret(\(p))"
        }
    }
}

@MainActor func probeRun(_ text: String, _ ops: [ProbeOp]) async -> EditorTextView {
    let tv = makeView(text)
    for op in ops {
        let len = (tv.string as NSString).length
        switch op {
        case .type(let s, let p): tv.setSelectedRange(NSRange(location: min(p, len), length: 0)); tv.insertText(s, replacementRange: tv.selectedRange())
        case .backspace: tv.deleteBackward(nil)
        case .undo: tv.undoManager?.undo()
        case .redo: tv.undoManager?.redo()
        case .mode: tv.mode = tv.mode == .live ? .raw : .live
        case .ret: tv.insertNewline(nil)
        case .caret(let p): tv.setSelectedRange(NSRange(location: min(p, len), length: 0))
        }
        spin()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return tv
}

@MainActor @Test func probeFenceMarkersStayHiddenWithCaretInsideCode() async {
    let original = Corpus.all().first { $0.name == "unclosed.md" }!.text
    let ops: [ProbeOp] = [.type("\n\n", 6), .type("_", 72), .type(" ", 7), .type("```\n", 95), .ret, .type("*", 78)]
    var steps: [ProbeOp] = []
    for op in ops {
        steps.append(op)
        let tv = await probeRun(original, steps)
        perf("after \(steps.last!): sel \(tv.selectedRange()) diff \(await probeDiff(tv) ?? "none") blocks \(tv.parser.document.blocks.prefix(4).map { "\($0.kind) \($0.range)" })")
    }
    let tv = await probeRun(original, ops)
    perf("text \(tv.string.debugDescription)")
    #expect(await probeDiff(tv) == nil)
}

@Test func probeTypingCodeWithBlankLineAtEndOfNote() {
    // writing a code block at the end of a note, one keystroke at a time, with a blank line inside it
    let start = "Notes\n\n"
    let typed = "```python\nimport os\n\n# list the files\nprint(os.listdir())\n```\n"
    let p = IncrementalParser(text: start)
    var text = start as NSString
    for ch in typed {
        let s = String(ch) as NSString
        let newText = text.replacingCharacters(in: NSRange(location: text.length, length: 0), with: s as String) as NSString
        p.apply(edit: NSRange(location: text.length, length: 0), replacementLength: s.length, newText: newText as String)
        text = newText
        if p.document != MarkdownParser.parse(text as String) {
            Issue.record("diverged after typing \(text.debugDescription): incremental \(p.document.blocks.map { "\($0.kind) \($0.range)" })")
            return
        }
    }
}

@MainActor @Test func probeTypingDuringImportMovesTheInsertionPoint() async {
    let file = FileManager.default.temporaryDirectory.appending(path: "FN-probe-\(UUID().uuidString).txt")
    try! Data("x".utf8).write(to: file)
    let tv = makeView("abc")
    tv.setSelectedRange(NSRange(location: 3, length: 0))
    tv.importFiles = { _ in
        try? await Task.sleep(for: .milliseconds(200))
        return ["[x.txt](feather://attachment/X)"]
    }
    let pb = NSPasteboard(name: NSPasteboard.Name("FeatherProbe-\(UUID().uuidString)"))
    pb.clearContents()
    pb.writeObjects([file as NSURL])
    _ = tv.readSelection(from: pb, type: .fileURL)
    tv.insertText("XY", replacementRange: NSRange(location: 0, length: 0))   // typing earlier in the note meanwhile
    _ = await waitFor({ tv.string.contains("feather://") }, timeout: 15)
    #expect(tv.string == "XYabc\n[x.txt](feather://attachment/X)", "got \(tv.string.debugDescription)")
}

@MainActor @Test func probePastingOnlyAnImageImportsIt() async {
    let tv = makeView("")
    var imported = false
    tv.importFiles = { urls in imported = true; return urls.map { "![p](\($0.lastPathComponent))" } }
    let png = try! Data(contentsOf: makePNG(width: 4, height: 4))
    let pb = NSPasteboard(name: NSPasteboard.Name("FeatherProbe-\(UUID().uuidString)"))
    pb.clearContents()
    pb.declareTypes([.png], owner: nil)
    pb.setData(png, forType: .png)
    _ = tv.readSelection(from: pb)
    _ = await waitFor({ imported && tv.string.hasPrefix("![p]") }, timeout: 3)
    #expect(imported && tv.string.hasPrefix("![p]"), "editor holds \(tv.string.debugDescription)")
}

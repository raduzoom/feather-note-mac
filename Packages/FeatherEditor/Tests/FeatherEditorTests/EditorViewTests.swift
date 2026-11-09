import AppKit
import Testing
@testable import FeatherEditor

@MainActor func makeView(_ text: String) -> EditorTextView {
    let tv = EditorTextView.make()
    tv.setFrameSize(NSSize(width: 700, height: 600))
    tv.load(text)
    return tv
}

@MainActor func hiddenRanges(_ tv: EditorTextView) -> [NSRange] {
    var out: [NSRange] = []
    guard let storage = tv.textStorage else { return [] }
    storage.enumerateAttribute(.featherHidden, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
        if v as? Bool == true { out.append(r) }
    }
    return out
}

/// Lets the run loop close the undo manager's per-event group, as real keystrokes do.
@MainActor func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

@MainActor func caretInsideHidden(_ tv: EditorTextView) -> Bool {
    let p = tv.selectedRange().location
    return hiddenRanges(tv).contains { $0.location < p && p < NSMaxRange($0) }
}

@MainActor @Suite struct EditorViewTests {
    @Test func loadKeepsBytesAndClearsUndo() {
        let t = "# H\r\n\r\n- a **b**\r\n"
        let tv = makeView(t)
        #expect(Array(tv.string.utf8) == Array(t.utf8))
        #expect(tv.undoManager?.canUndo != true)
        #expect(tv.textLayoutManager != nil)
    }

    @Test func caretNeverRestsInsideHiddenMarker() {
        for t in ["a **bold** b", "- item one\n- item two", "x `code` y [link](url) z", "- [ ] task\n\n> quote\n> more"] {
            let tv = makeView(t)
            let length = (t as NSString).length
            for selector in [#selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveWordRight(_:))] {
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                for _ in 0..<length + 2 {
                    tv.doCommand(by: selector)
                    #expect(!caretInsideHidden(tv), "\(t.debugDescription) \(selector) at \(tv.selectedRange().location)")
                }
                #expect(tv.selectedRange().location == length, "\(t.debugDescription) \(selector) reached \(tv.selectedRange().location)")
            }
            for selector in [#selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveWordLeft(_:))] {
                tv.setSelectedRange(NSRange(location: length, length: 0))
                for _ in 0..<length + 2 {
                    tv.doCommand(by: selector)
                    #expect(!caretInsideHidden(tv), "\(t.debugDescription) \(selector) at \(tv.selectedRange().location)")
                }
            }
            for i in 0...length {   // clicks land on arbitrary indices
                tv.setSelectedRange(NSRange(location: i, length: 0))
                #expect(!caretInsideHidden(tv), "\(t.debugDescription) click \(i) → \(tv.selectedRange().location)")
            }
        }
    }

    @Test func adjustedSelectionMovesInDirectionOfTravel() {
        let tv = makeView("- item")
        // "- " is hidden; index 1 is inside it
        #expect(tv.adjustedSelection(NSRange(location: 1, length: 0), from: NSRange(location: 0, length: 0)).location == 2)
        #expect(tv.adjustedSelection(NSRange(location: 1, length: 0), from: NSRange(location: 3, length: 0)).location == 0)
    }

    @Test func shiftSelectAcrossHiddenIncludesWhole() {
        let tv = makeView("- one\n- two")
        let r = tv.adjustedSelection(NSRange(location: 1, length: 6), from: NSRange(location: 1, length: 0))
        for h in hiddenRanges(tv) where NSIntersectionRange(h, r).length > 0 {
            #expect(NSIntersectionRange(h, r) == h)
        }
    }

    @Test func revealFollowsTheCaret() {
        let tv = makeView("a **bold** b")
        #expect(hiddenRanges(tv).contains(NSRange(location: 2, length: 2)))
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(!hiddenRanges(tv).contains { NSIntersectionRange($0, NSRange(location: 2, length: 2)).length > 0 })
        tv.setSelectedRange(NSRange(location: 12, length: 0))
        #expect(hiddenRanges(tv).contains(NSRange(location: 2, length: 2)))
    }

    @Test func typingAfterBoldGoesOutside() {
        let tv = makeView("**b**")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText("x", replacementRange: tv.selectedRange())
        #expect(tv.string == "**b**x")
        let f = tv.textStorage!.attribute(.font, at: 5, effectiveRange: nil) as! NSFont
        #expect(!f.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func returnContinuesListThroughTheView() {
        let tv = makeView("- one")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "- one\n- " && tv.selectedRange().location == 8)
    }

    @Test func checkboxToggleUndoes() {
        let tv = makeView("- [ ] task")
        tv.toggleCheckbox(at: 2)
        #expect(tv.string == "- [x] task")
        tv.undoManager?.undo()
        #expect(tv.string == "- [ ] task")
    }

    @Test func stylingRegistersNoUndo() {
        let tv = makeView("a **b** c\n\n- [ ] t\n\n```\nx\n```")
        for i in 0..<10 { tv.setSelectedRange(NSRange(location: i * 2, length: 0)) }
        tv.mode = .raw
        tv.mode = .live
        #expect(tv.undoManager?.canUndo == false)
    }

    @Test func undoGroupsByReturn() {
        let tv = makeView("")
        tv.insertText("first", replacementRange: tv.selectedRange()); spin()
        tv.insertNewline(nil); spin()
        tv.insertText("second", replacementRange: tv.selectedRange()); spin()
        tv.undoManager?.undo()
        #expect(tv.string.hasPrefix("first"))
        #expect(!tv.string.contains("second"))
    }

    @Test func copyGivesMarkdownSource() {
        let tv = makeView("a **bold** [link](u) c")
        tv.selectAll(nil)
        let pb = NSPasteboard(name: NSPasteboard.Name("FeatherEditorTests-\(UUID().uuidString)"))
        #expect(tv.writeSelection(to: pb, types: [.string]))
        #expect(pb.string(forType: .string) == "a **bold** [link](u) c")
        #expect(pb.data(forType: .rtf) == nil)
    }

    @Test func noRestyleDuringMarkedText() {
        let tv = makeView("a **b** c")
        tv.setSelectedRange(NSRange(location: 4, length: 0))   // inside the bold: markers shown
        tv.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(tv.isComposing)
        let before = NSAttributedString(attributedString: tv.textStorage!)
        tv.restyleAll()   // what an edit or caret move would trigger
        #expect(tv.textStorage!.isEqual(to: before))
        tv.unmarkText()
        #expect(!tv.isComposing)
        #expect(tv.string == "a **´b** c")
    }

    @Test func eachNoteHasItsOwnUndo() {
        let tv = makeView("note one")
        tv.insertText("!", replacementRange: NSRange(location: 8, length: 0))
        #expect(tv.undoManager?.canUndo == true)
        tv.load("note two")
        #expect(tv.undoManager?.canUndo == false)
        tv.undoManager?.undo()
        #expect(tv.string == "note two")
    }
}

@MainActor func caretLineY(_ tv: EditorTextView) -> CGFloat? {
    guard let tlm = tv.textLayoutManager,
          let loc = tlm.location(tlm.documentRange.location, offsetBy: tv.selectedRange().location),
          let frag = tlm.textLayoutFragment(for: loc) else { return nil }
    return frag.layoutFragmentFrame.minY + tv.textContainerOrigin.y - tv.visibleRect.minY
}

@MainActor @Test func toggleKeepsBytesSelectionAndLine() {
    var lines: [String] = []
    for i in 0..<120 { lines.append(i % 10 == 0 ? "## Heading \(i)" : "Line **\(i)** with `code` and [link](u) text") }
    let text = lines.joined(separator: "\n\n")
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    let tv = EditorTextView.make()
    tv.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    scroll.documentView = tv
    tv.load(text)
    let target = (text as NSString).range(of: "Line **61**").location + 7
    tv.setSelectedRange(NSRange(location: target, length: 0))
    tv.scrollRangeToVisible(tv.selectedRange())
    tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let before = caretLineY(tv)
    let selection = tv.selectedRange()
    tv.mode = .raw
    tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
    #expect(Array(tv.string.utf8) == Array(text.utf8))
    #expect(tv.selectedRange() == selection)
    let raw = caretLineY(tv)
    #expect(before != nil && raw != nil && abs(raw! - before!) <= 26, "before \(String(describing: before)) raw \(String(describing: raw))")
    tv.mode = .live
    tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let after = caretLineY(tv)
    #expect(Array(tv.string.utf8) == Array(text.utf8) && tv.selectedRange() == selection)
    #expect(after != nil && abs(after! - before!) <= 26, "before \(String(describing: before)) after \(String(describing: after))")
}

/// Styling work stays proportional to what changed, not to the note's length.
@MainActor @Suite struct RestyleScopeTests {
    let text = "First **bold** paragraph.\n\n" + String(repeating: "Middle paragraph with *some* words.\n\n", count: 400) + "Last **bold** paragraph."

    @Test func loadStylesTheNoteOnce() {
        let tv = EditorTextView.make()
        tv.setFrameSize(NSSize(width: 700, height: 600))
        tv.restyledCharacters = 0
        tv.load(text)
        #expect(tv.restyledCharacters == (text as NSString).length)
    }

    @Test func keystrokeStylesItsParagraphOnce() {
        let tv = makeView(text)
        let at = (text as NSString).range(of: "Middle paragraph with").location + 3
        tv.setSelectedRange(NSRange(location: at, length: 0))
        tv.restyledCharacters = 0
        tv.insertText("x", replacementRange: tv.selectedRange())
        #expect(tv.restyledCharacters <= 40, "restyled \(tv.restyledCharacters) for a 37-character paragraph")
        #expect(font(tv.textStorage!, at + 21).fontDescriptor.symbolicTraits.contains(.italic))   // the s of *some*, after the inserted x
    }

    @Test func caretJumpRestylesOnlyTheTwoParagraphs() {
        let tv = makeView(text)
        let length = (text as NSString).length
        tv.setSelectedRange(NSRange(location: length, length: 0))
        tv.restyledCharacters = 0
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(tv.restyledCharacters < 200, "restyled \(tv.restyledCharacters) of \(length)")
    }
}

/// A long note opens styled around the caret; the rest is styled in small chunks right after.
@MainActor @Suite struct BackgroundStylingTests {
    let text = "First **bold** paragraph.\n\n" + String(repeating: "Middle paragraph with *some* words.\n\n", count: 3_000) + "Last **bold** paragraph."
    func isBold(_ tv: EditorTextView, _ i: Int) -> Bool { font(tv.textStorage!, i).fontDescriptor.symbolicTraits.contains(.bold) }
    func isItalic(_ tv: EditorTextView, _ i: Int) -> Bool { font(tv.textStorage!, i).fontDescriptor.symbolicTraits.contains(.italic) }

    @Test func longNoteStylesNearTheCaretFirst() async {
        let tv = EditorTextView.make()
        tv.setFrameSize(NSSize(width: 700, height: 600))
        tv.load(text)
        #expect(tv.restyledCharacters <= 40_000)
        #expect(isBold(tv, (text as NSString).range(of: "bold").location))
        #expect(await waitFor({ tv.isFullyStyled }, timeout: 10))
        #expect(isBold(tv, (text as NSString).range(of: "bold", options: .backwards).location))
    }

    @Test func editsWhileStylingKeepTheRestAligned() async {
        let tv = EditorTextView.make()
        tv.setFrameSize(NSSize(width: 700, height: 600))
        tv.load(text)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("Hello **there**\n\n", replacementRange: NSRange(location: 0, length: 0))
        let far = (tv.string as NSString).length - 30_000
        tv.insertText("x", replacementRange: NSRange(location: far, length: 0))
        tv.insertText("", replacementRange: NSRange(location: far - 200, length: 37))
        #expect(await waitFor({ tv.isFullyStyled }, timeout: 10))
        let s = tv.string as NSString
        var wrong = 0
        var r = NSRange(location: 0, length: s.length)
        while true {
            let m = s.range(of: "*some*", options: [], range: r)
            guard m.location != NSNotFound else { break }
            if !isItalic(tv, m.location + 1) { wrong += 1 }
            r = NSRange(location: NSMaxRange(m), length: s.length - NSMaxRange(m))
        }
        #expect(wrong == 0)
        #expect(isBold(tv, s.range(of: "bold", options: .backwards).location))
    }
}

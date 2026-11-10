import AppKit
import Testing
@testable import FeatherEditor

/// Types `s` one character at a time, as keystrokes do.
@MainActor func type(_ tv: EditorTextView, _ s: String) {
    for c in s { tv.insertText(String(c), replacementRange: tv.selectedRange()); spin() }
}

@MainActor @Suite struct BlockMenuViewTests {
    @Test func slashAtLineStartOpensAndReturnPicks() {
        let tv = makeView("")
        type(tv, "/")
        #expect(tv.blockMenu.isOpen && tv.blockMenu.state.items.count == 11)
        type(tv, "h2")
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(tv.string == "## " && tv.selectedRange().location == 3 && !tv.blockMenu.isOpen)
    }

    @Test func arrowsMoveTheSelection() {
        let tv = makeView("")
        type(tv, "/h")
        tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(tv.string == "### ")
    }

    @Test func escClosesAndKeepsTheText() {
        let tv = makeView("")
        type(tv, "/he")
        tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!tv.blockMenu.isOpen && tv.string == "/he")
    }

    @Test func pathAtLineStartStaysAsTyped() {
        let tv = makeView("")
        type(tv, "/usr/bin")
        #expect(!tv.blockMenu.isOpen && tv.string == "/usr/bin")
        tv.insertNewline(nil)
        #expect(tv.string == "/usr/bin\n")
    }

    @Test func slashMidSentenceOrInCodeDoesNotOpen() {
        let tv = makeView("and")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        type(tv, "/")
        #expect(!tv.blockMenu.isOpen)
        let code = makeView("```\n\n```")
        code.setSelectedRange(NSRange(location: 4, length: 0))
        type(code, "/")
        #expect(!code.blockMenu.isOpen)
        let raw = makeView("")
        raw.mode = .raw
        type(raw, "/")
        #expect(!raw.blockMenu.isOpen)
    }

    @Test func inputMethodSlashDoesNotOpen() {
        let tv = makeView("")
        tv.setMarkedText("／", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText("／", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!tv.blockMenu.isOpen)
    }

    @Test func menuClosesWhenCaretLeavesOrNoteLoads() {
        let tv = makeView("first\n")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        type(tv, "/")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!tv.blockMenu.isOpen)
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.deleteBackward(nil); type(tv, "/")
        #expect(tv.blockMenu.isOpen)
        tv.load("other")
        #expect(!tv.blockMenu.isOpen && tv.blockTrigger == nil)
    }

    @Test func pickIsOneUndoStep() {
        let tv = makeView("hello")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        type(tv, "/q")
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(tv.string == "> hello")
        tv.undoManager?.undo()
        #expect(tv.string == "/qhello")
    }

    @Test func deletingTheSlashCloses() {
        let tv = makeView("")
        type(tv, "/")
        tv.deleteBackward(nil)
        #expect(!tv.blockMenu.isOpen && tv.string == "")
    }

    @Test func plusButtonFollowsTheCaret() throws {
        let tv = makeView("a\n\nb")
        tv.blockButtonShowsWithoutFocus = true   // tests have no key window
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let top = try #require(tv.blockButtonFrame())
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        let lower = try #require(tv.blockButtonFrame())
        #expect(lower.minY > top.minY && top.maxX <= tv.textContainerOrigin.x)
        tv.setSelectedRange(NSRange(location: 0, length: 1)); #expect(tv.blockButtonFrame() == nil)
        tv.setSelectedRange(NSRange(location: 0, length: 0)); tv.mode = .raw; #expect(tv.blockButtonFrame() == nil)
        let code = makeView("```\nx\n```"); code.blockButtonShowsWithoutFocus = true
        code.setSelectedRange(NSRange(location: 4, length: 0)); #expect(code.blockButtonFrame() == nil)
    }

    @Test func plusPickTurnsTheLineInto() {
        let tv = makeView("hello")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.openBlockMenuFromButton()
        #expect(tv.blockTrigger == .plus)
        tv.pickBlock(.heading1)
        #expect(tv.string == "# hello")
        tv.undoManager?.undo()
        #expect(tv.string == "hello")
    }

    @Test func imageOrFileGoesThroughTheChooser() async {
        let tv = makeView("hello\nnext")
        tv.importFiles = { _ in ["![a](feather://attachment/01J)"] }
        tv.chooseFiles = { done in done([URL(fileURLWithPath: "/tmp/a.png")]) }
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.pickBlock(.imageOrFile)
        #expect(await waitFor { tv.string == "hello\n\n![a](feather://attachment/01J)\n\nnext" })
    }

    @Test func slashImageReplacesTheEmptyLine() async {
        let tv = makeView("")
        tv.importFiles = { _ in ["[f.pdf](feather://attachment/01K)"] }
        tv.chooseFiles = { done in done([URL(fileURLWithPath: "/tmp/f.pdf")]) }
        type(tv, "/file")
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(await waitFor { tv.string == "[f.pdf](feather://attachment/01K)" })
    }

    @Test func cancelledChooserChangesNothing() {
        let tv = makeView("hello")
        tv.chooseFiles = { done in done([]) }
        tv.pickBlock(.imageOrFile)
        #expect(tv.string == "hello" && tv.undoManager?.canUndo == false)
    }

    @Test func pickedFileAfterNoteSwitchIsDropped() async {
        let tv = makeView("one")
        var finish: (([URL]) -> Void)?
        tv.importFiles = { _ in ["![a](feather://attachment/01J)"] }
        tv.chooseFiles = { finish = $0 }
        tv.pickBlock(.imageOrFile)
        tv.load("two")
        finish?([URL(fileURLWithPath: "/tmp/a.png")])
        try? await Task.sleep(for: .milliseconds(200))
        #expect(tv.string == "two")
    }

    @Test func scanOffersContinuityCameraAtTheLineEnd() {
        let tv = makeView("hello\nnext")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.presentsMenus = false   // record instead of popping up
        tv.pickBlock(.scan)
        #expect(tv.scanMenu().items.contains { $0.identifier == NSMenuItem.importFromDeviceIdentifier })
        #expect(tv.selectedRange() == NSRange(location: 5, length: 0) && tv.lastPresentedMenu != nil)
    }

    // Review fixes (Phase 5.1 final review)

    @Test func movingTheCaretInsideTheQueryCloses() {
        let tv = makeView("hello")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        type(tv, "/")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(!tv.blockMenu.isOpen)
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(tv.string == "/h\nello")
        let typo = makeView("")
        type(typo, "/heading")
        typo.setSelectedRange(NSRange(location: 7, length: 0))
        #expect(!typo.blockMenu.isOpen && typo.string == "/heading")
    }

    @Test func pastedFilesInACRLFNoteKeepItsEndings() async {
        let tv = makeView("hello\r\nnext")
        tv.insertAttachmentSnippets(["![a](x)"], at: NSRange(location: 5, length: 0))
        #expect(tv.string == "hello\r\n![a](x)\r\nnext")
    }

    @Test func scanResultLandsAsItsOwnBlock() async throws {
        let tv = makeView("hello\nnext")
        tv.importFiles = { _ in ["![Scan](feather://attachment/01S)"] }
        tv.presentsMenus = false
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.pickBlock(.scan)
        let pb = NSPasteboard(name: .init("FeatherScanTest-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/scan.pdf") as NSURL])
        _ = tv.readSelection(from: pb, type: .fileURL)
        #expect(await waitFor { tv.string == "hello\n\n![Scan](feather://attachment/01S)\n\nnext" })
        pb.releaseGlobally()
    }

    @Test func plusPanelLosingKeyDoesNotTakeFocusBack() throws {
        let (window, tv) = windowed("hello")
        defer { window.close() }
        tv.openBlockMenuFromButton()
        let panel = try #require(tv.blockMenu.panel)
        panel.onResignKey()
        #expect(!tv.blockMenu.isOpen && tv.focusRestores == 0)
        tv.openBlockMenuFromButton()
        _ = tv.blockMenu.handle(#selector(NSResponder.cancelOperation(_:)))
        #expect(!tv.blockMenu.isOpen && tv.focusRestores == 1)
    }

    @Test func plusSearchFieldStartsEmpty() {
        let (window, tv) = windowed("hello")
        defer { window.close() }
        tv.openBlockMenuFromButton()
        tv.blockMenu.search.stringValue = "co"
        _ = tv.blockMenu.handle(#selector(NSResponder.cancelOperation(_:)))
        tv.openBlockMenuFromButton()
        #expect(tv.blockMenu.search.stringValue == "")
    }
}

/// An editor in an offscreen window, so the menu panel exists.
@MainActor func windowed(_ text: String) -> (NSWindow, EditorTextView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let tv = makeView(text)
    window.contentView = tv
    return (window, tv)
}

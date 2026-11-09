import Foundation
import Testing
@testable import FeatherEditor

/// Applies a command's edit to `text` and returns the new text with "|" at the caret.
func run(_ text: String, caret: Int, _ command: (String, MarkdownDocument, NSRange) -> EditorCommands.Edit?) -> String? {
    guard let e = command(text, MarkdownParser.parse(text), NSRange(location: caret, length: 0)) else { return nil }
    let new = (text as NSString).replacingCharacters(in: e.range, with: e.replacement) as NSString
    return new.replacingCharacters(in: NSRange(location: e.selection.location, length: 0), with: "|")
}

func caretIn(_ withBar: String) -> (String, Int) {
    let r = (withBar as NSString).range(of: "|")
    return ((withBar as NSString).replacingCharacters(in: r, with: ""), r.location)
}

func returnKey(_ s: String) -> String? { let (t, c) = caretIn(s); return run(t, caret: c, EditorCommands.returnKey) }
func tab(_ s: String) -> String? { let (t, c) = caretIn(s); return run(t, caret: c, EditorCommands.tab) }
func backtab(_ s: String) -> String? { let (t, c) = caretIn(s); return run(t, caret: c, EditorCommands.backtab) }
func backspace(_ s: String) -> String? { let (t, c) = caretIn(s); return run(t, caret: c, EditorCommands.backspaceAtItemStart) }

@Test func returnContinuesLists() {
    #expect(returnKey("- one|") == "- one\n- |")
    #expect(returnKey("* one|") == "* one\n* |")
    #expect(returnKey("1. one|") == "1. one\n2. |")
    #expect(returnKey("9) one|") == "9) one\n10) |")
    #expect(returnKey("- [x] done|") == "- [x] done\n- [ ] |")
    #expect(returnKey("  - nested|") == "  - nested\n  - |")
    #expect(returnKey("- on|e") == "- on\n- |e")
    #expect(returnKey("- one|\r\n- two") == "- one\r\n- |\r\n- two")
}

@Test func returnOnEmptyItemEndsList() {
    #expect(returnKey("- one\n- |") == "- one\n|")
    #expect(returnKey("- one\n- [ ] |") == "- one\n|")
    #expect(returnKey("1. a\n2. |") == "1. a\n|")
}

@Test func returnInCodeKeepsIndent() {
    #expect(returnKey("```\n    let x|\n```") == "```\n    let x\n    |\n```")
    #expect(returnKey("plain|") == nil)
    #expect(returnKey("# Heading|") == nil)
}

@Test func tabIndentsUnderPreviousItem() {
    #expect(tab("- one\n- tw|o") == "- one\n  - tw|o")
    #expect(tab("1. one\n2. tw|o") == "1. one\n   2. tw|o")
    #expect(tab("- one\n  - two\n  - th|ree") == "- one\n  - two\n    - th|ree")
    #expect(tab("- fi|rst") == nil)   // nothing to nest under
    #expect(tab("```\nx|\n```") == "```\nx    |\n```")
    #expect(tab("plain|") == nil)
}

@Test func backtabOutdents() {
    #expect(backtab("- one\n  - tw|o") == "- one\n- tw|o")
    #expect(backtab("- on|e") == nil)
    #expect(backtab("```\n    x|\n```") == "```\nx|\n```")
}

@Test func backspaceAtItemStartRemovesMarker() {
    #expect(backspace("- |one") == "|one")
    #expect(backspace("- [ ] |task") == "|task")
    #expect(backspace("> |quote") == "|quote")
    #expect(backspace("- o|ne") == nil)
    #expect(backspace("|plain") == nil)
}

@Test func toggleCheckboxEditsOnlyTheBox() {
    let t = "- [ ] a\n- [x] b\n- [X] c"
    func toggled(_ at: Int) -> String? {
        guard let e = EditorCommands.toggleCheckbox(text: t, document: MarkdownParser.parse(t), at: at) else { return nil }
        #expect(e.range.length == 3)
        return (t as NSString).replacingCharacters(in: e.range, with: e.replacement)
    }
    #expect(toggled(2) == "- [x] a\n- [x] b\n- [X] c")
    #expect(toggled(10) == "- [ ] a\n- [ ] b\n- [X] c")
    #expect(toggled(18) == "- [ ] a\n- [x] b\n- [ ] c")
    #expect(EditorCommands.toggleCheckbox(text: "plain", document: MarkdownParser.parse("plain"), at: 1) == nil)
}

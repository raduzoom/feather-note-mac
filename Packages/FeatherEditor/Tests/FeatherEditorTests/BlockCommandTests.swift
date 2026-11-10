import AppKit
import Testing
@testable import FeatherEditor

@Test func matchingFollowsMenuOrder() {
    #expect(BlockChoice.matching("") == BlockChoice.allCases)
    #expect(BlockChoice.matching("h") == [.heading1, .heading2, .heading3])
    #expect(BlockChoice.matching("H2") == [.heading2])
    #expect(BlockChoice.matching("heading 3") == [.heading3])
    #expect(BlockChoice.matching("list") == [.bulleted, .numbered, .todo])
    #expect(BlockChoice.matching("task") == [.todo])
    #expect(BlockChoice.matching("hr") == [.divider])
    #expect(BlockChoice.matching("code") == [.code])
    #expect(BlockChoice.matching("photo") == [.imageOrFile])
    #expect(BlockChoice.matching("iphone") == [.scan])
    #expect(BlockChoice.matching("usr").isEmpty)
    #expect(BlockChoice.matching(" h").isEmpty)
}

@Test func choiceCopy() {
    #expect(BlockChoice.allCases.map(\.title) == ["Heading 1", "Heading 2", "Heading 3", "Bulleted list", "Numbered list",
        "To-do list", "Quote", "Divider", "Code block", "Image or file", "Scan from iPhone"])
    #expect(BlockChoice.allCases.filter(\.isTextBlock) == [.heading1, .heading2, .heading3, .bulleted, .numbered, .todo, .quote])
    #expect(BlockChoice.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) != nil })
}

/// Applies a block choice to `withBar` ("|" marks the caret) and returns the new text with "|" at the caret.
func blk(_ choice: BlockChoice, _ withBar: String, trigger: NSRange? = nil) -> String? {
    let (text, caret) = caretIn(withBar)
    guard let e = EditorCommands.block(choice, text: text, caret: caret, removing: trigger) else { return nil }
    let new = (text as NSString).replacingCharacters(in: e.range, with: e.replacement) as NSString
    return new.replacingCharacters(in: NSRange(location: e.selection.location, length: 0), with: "|")
}

@Test func emptyLineStartsTextBlocks() {
    #expect(blk(.heading1, "|") == "# |")
    #expect(blk(.heading2, "|") == "## |")
    #expect(blk(.heading3, "|") == "### |")
    #expect(blk(.bulleted, "|") == "- |")
    #expect(blk(.numbered, "|") == "1. |")
    #expect(blk(.todo, "|") == "- [ ] |")
    #expect(blk(.quote, "a\n\n|") == "a\n\n> |")
}

@Test func textLineTurnsInto() {
    #expect(blk(.heading1, "hel|lo") == "# hello|")
    #expect(blk(.todo, "hello|\nnext") == "- [ ] hello|\nnext")
    #expect(blk(.quote, "|hello") == "> hello|")
}

@Test func turnIntoReplacesExistingMarkers() {
    #expect(blk(.heading1, "## a|") == "# a|")
    #expect(blk(.bulleted, "- [x] a|") == "- a|")
    #expect(blk(.todo, "1. a|") == "- [ ] a|")
    #expect(blk(.heading2, "> - a|") == "## a|")
    #expect(blk(.numbered, "  - a|") == "  1. a|")
    #expect(blk(.heading1, "# a|") == "# a|")
}

@Test func numberedContinuesTheListAbove() {
    #expect(blk(.numbered, "1. a\n2. b\n|") == "1. a\n2. b\n3. |")
    #expect(blk(.numbered, "1. a\n\nx|") == "1. a\n\n1. x|")
}

@Test func codeAndDividerOnAnEmptyLine() {
    #expect(blk(.code, "|") == "```\n|\n```")
    #expect(blk(.code, "a\n|\nb") == "a\n```\n|\n```\nb")
    #expect(blk(.divider, "|") == "---\n|")
    #expect(blk(.divider, "a\n\n|\nb") == "a\n\n---\n|\nb")
}

@Test func codeAndDividerGoBelowText() {
    #expect(blk(.code, "hel|lo\nnext") == "hello\n```\n|\n```\nnext")
    #expect(blk(.divider, "hello|") == "hello\n\n---\n|")
}

@Test func dividerNeverMakesASetextHeading() {
    #expect(blk(.divider, "a\n|") == "a\n\n---\n|")
    #expect(MarkdownParser.parse("a\n\n---\n").blocks.contains { $0.kind == .thematicBreak })
}

@Test func belowBlocksKeepTheContainer() {
    #expect(blk(.code, "- item|") == "- item\n  ```\n  |\n  ```")
    #expect(blk(.code, "> q|") == "> q\n> ```\n> |\n> ```")
    #expect(blk(.divider, "- item|") == "- item\n\n  ---\n  |")
    #expect(blk(.divider, "> q|") == "> q\n>\n> ---\n> |")
}

@Test func crlfLinesKeepTheirEnding() {
    #expect(blk(.code, "a|\r\nb") == "a\r\n```\r\n|\r\n```\r\nb")
    #expect(blk(.heading1, "a|\r\nb") == "# a|\r\nb")
    #expect(blk(.divider, "a\r\n|") == "a\r\n\r\n---\r\n|")
}

@Test func triggerIsRemovedInTheSameEdit() {
    #expect(blk(.heading1, "/h1|", trigger: NSRange(location: 0, length: 3)) == "# |")
    #expect(blk(.quote, "/q|hello", trigger: NSRange(location: 0, length: 2)) == "> hello|")
    #expect(blk(.code, "- /co|", trigger: NSRange(location: 2, length: 3)) == "```\n|\n```")
    #expect(BlockChoice.allCases.filter { !$0.isTextBlock && $0 != .code && $0 != .divider }
        .allSatisfy { EditorCommands.block($0, text: "x", caret: 1, removing: nil) == nil })
}

@Test func mediaInsertionPoint() {
    let empty = EditorCommands.mediaInsertionPoint(text: "a\n/im\nb", caret: 5, removing: NSRange(location: 2, length: 3))
    #expect(empty.edit?.replacement == "" && empty.location == 2)
    let text = EditorCommands.mediaInsertionPoint(text: "hello\nb", caret: 2, removing: nil)
    #expect(text.edit == nil && text.location == 5)
}

@Test func slashOpensOnlyAtTheStartOfALinesText() {
    func opens(_ withBar: String) -> Bool {
        let (t, c) = caretIn(withBar)
        let text = (t as NSString).replacingCharacters(in: NSRange(location: c, length: 0), with: "/")
        return EditorCommands.slashOpensMenu(text: text, document: MarkdownParser.parse(text), slashAt: c)
    }
    #expect(opens("|") && opens("  |") && opens("- |") && opens("- [ ] |") && opens("> |") && opens("## |"))
    #expect(opens("|hello") && opens("- |hello") && opens("a\n|"))
    #expect(!opens("a |") && !opens("and|or") && !opens("http:|"))
    #expect(!opens("```\n|\n```") && !opens("    code\n    |"))
    #expect(!opens("<div>\n|\n</div>"))
}

@Test func menuStateFiltersAndWraps() {
    var s = BlockMenuState()
    #expect(s.items == BlockChoice.allCases && s.selection == .heading1)
    s.move(-1); #expect(s.selection == .scan)
    s.move(1); s.move(1); #expect(s.selection == .heading2)
    let list = s.setQuery("list")
    #expect(list && s.items == [.bulleted, .numbered, .todo] && s.selected == 0)
    let noMatch = s.setQuery("listz"), space = s.setQuery(" h"), long = s.setQuery(String(repeating: "a", count: 25))
    #expect(!noMatch && !space && !long && s.query == "list")
}

// Review fixes (Phase 5.1 final review)

func media(_ snippets: [String], _ withBar: String) -> String {
    let (text, at) = caretIn(withBar)
    let e = EditorCommands.mediaEdit(snippets, text: text, at: at)
    return (text as NSString).replacingCharacters(in: e.range, with: e.replacement)
}

@Test func mediaBelowTextIsItsOwnParagraph() {
    #expect(media(["![a](x)"], "hello|\nnext") == "hello\n\n![a](x)\n\nnext")
    #expect(media(["![a](x)"], "hello|") == "hello\n\n![a](x)")
    #expect(media(["![a](x)", "![b](y)"], "hello|") == "hello\n\n![a](x)\n\n![b](y)")
    let doc = MarkdownParser.parse(media(["![a](x)"], "hello|\nnext"))
    #expect(doc.blocks.contains { if case .image = $0.kind { return true }; return false })
}

@Test func mediaOnAnEmptyLine() {
    #expect(media(["[f](x)"], "|") == "[f](x)")
    #expect(media(["![a](x)"], "a\n|") == "a\n\n![a](x)")
    #expect(media(["![a](x)"], "a\n\n|\nb") == "a\n\n![a](x)\n\nb")
}

@Test func mediaKeepsTheContainerAndLineEnding() {
    #expect(media(["![a](x)"], "- item|") == "- item\n\n  ![a](x)")
    #expect(media(["![a](x)"], "> q|") == "> q\n>\n> ![a](x)")
    #expect(media(["![a](x)"], "hello|\r\nnext") == "hello\r\n\r\n![a](x)\r\n\r\nnext")
}

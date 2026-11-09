import AppKit
import Testing
@testable import FeatherEditor

/// Where decorations land relative to the text (found by rendering the editor and comparing with the boards).
@MainActor @Suite struct LayoutGeometryTests {
    static let text = "Body text.\n\n- [x] Raspberry\n- Spare cables\n  - USB-C\n\n> Mount it.\n\n[spec.pdf](feather://attachment/A)\n\n```\none\ntwo\nthree\n```\n"

    func paragraphStyle(_ s: NSTextStorage, _ i: Int) -> NSParagraphStyle? { s.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle }
    func at(_ needle: String) -> Int { (Self.text as NSString).range(of: needle).location }

    @Test func nestedItemsAndQuotesAreStyledFromTheLineStart() {
        let s = styled(Self.text)
        let nested = at("  - USB-C"), quote = at("> Mount")
        #expect(paragraphStyle(s, nested)?.headIndent == 48)
        #expect(decoration(s, nested) == .bullet(depth: 1))
        #expect((paragraphStyle(s, quote)?.headIndent ?? 0) >= 16)
        #expect(decoration(s, quote) == .quote(depth: 1, first: true, last: true))
    }

    func layout() -> (EditorTextView, [DecoratedLayoutFragment]) {
        let tv = EditorTextView.make()
        tv.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
        tv.load(Self.text)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let tlm = tv.textLayoutManager!
        var frags: [DecoratedLayoutFragment] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) {
            if let f = $0 as? DecoratedLayoutFragment { frags.append(f) }
            return true
        }
        return (tv, frags)
    }

    func fragment(_ frags: [DecoratedLayoutFragment], starting prefix: String) -> DecoratedLayoutFragment {
        frags.first { ($0.textElement as? NSTextParagraph)?.attributedString.string.hasPrefix(prefix) == true }!
    }

    /// Container x of the character at `index` within the fragment's paragraph.
    func textX(_ f: DecoratedLayoutFragment, _ index: Int) -> CGFloat {
        f.layoutFragmentFrame.minX + f.textLineFragments[0].locationForCharacter(at: index).x
    }

    @Test func checkboxSitsLeftOfItsText() {
        let (_, frags) = layout()
        let f = fragment(frags, starting: "- [x]")
        let box = f.checkboxRect!.offsetBy(dx: f.layoutFragmentFrame.minX, dy: 0)
        #expect(box.minX >= 0)
        #expect(box.maxX + 8 <= textX(f, 6) + 0.5, "box \(box), text at \(textX(f, 6))")
    }

    @Test func bulletSitsLeftOfItsText() {
        let (_, frags) = layout()
        let f = fragment(frags, starting: "- Spare")
        let bullet = f.bulletRect!.offsetBy(dx: f.layoutFragmentFrame.minX, dy: 0)
        #expect(bullet.minX >= 0)
        #expect(bullet.maxX <= textX(f, 2), "bullet \(bullet), text at \(textX(f, 2))")
    }

    @Test func chipStaysInsideTheTextColumn() {
        let (_, frags) = layout()
        let f = fragment(frags, starting: "[spec.pdf]")
        let pill = f.chipRects.first!.offsetBy(dx: f.layoutFragmentFrame.minX, dy: 0)
        #expect(pill.minX >= 0, "pill \(pill)")
        // where "s" of spec.pdf starts: the second letter's x minus the first's width (the first letter's
        // own x is ambiguous right after the kerned "[")
        let first = NSAttributedString(string: "s", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).size().width
        let nameStart = textX(f, 2) - first
        let badgeEnd = pill.minX + 4 + 32
        #expect(badgeEnd + 4 <= nameStart, "badge ends at \(badgeEnd), name starts at \(nameStart)")
        #expect(pill.minX <= nameStart - 40, "pill \(pill) should begin at the hidden [")
    }

    @Test func nestedItemTextIsOneStepRightOfItsParent() {
        let (_, frags) = layout()
        let parent = fragment(frags, starting: "- Spare"), child = fragment(frags, starting: "  - USB-C")
        #expect(abs(textX(child, 4) - textX(parent, 2) - 24) < 0.5, "parent \(textX(parent, 2)), child \(textX(child, 4))")
    }

    @Test func codeLineSurfacesMeetOnWholePoints() {
        let (_, frags) = layout()
        let lines = ["one", "two", "three"].map { name in let f = fragment(frags, starting: name); return f.surfaceRect(at: f.layoutFragmentFrame.origin) }
        for (a, b) in zip(lines, lines.dropFirst()) {
            let aBottom = a.maxY, bTop = b.minY
            #expect(aBottom == aBottom.rounded() && bTop == bTop.rounded())
        }
    }
}

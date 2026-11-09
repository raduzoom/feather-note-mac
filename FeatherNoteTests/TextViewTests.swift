import AppKit
import FeatherEditor
import Testing
@testable import FeatherNote

@MainActor @Test func editorTextViewHasNoSubstitutions() {
    for tv in [EditorTextView.make() as NSTextView, TitleEditor.makeTextView()] {
        #expect(!tv.isRichText)
        #expect(!tv.isAutomaticQuoteSubstitutionEnabled)
        #expect(!tv.isAutomaticDashSubstitutionEnabled)
        #expect(!tv.isAutomaticTextReplacementEnabled)
        #expect(!tv.isAutomaticSpellingCorrectionEnabled)
        #expect(!tv.isAutomaticLinkDetectionEnabled)
        #expect(!tv.isAutomaticDataDetectionEnabled)
        #expect(!tv.isAutomaticTextCompletionEnabled)
        #expect(!tv.smartInsertDeleteEnabled)
        #expect(tv.allowsUndo)
        tv.insertText("\"x\" -- (c) 'y'...", replacementRange: NSRange(location: 0, length: 0))
        #expect(tv.string == "\"x\" -- (c) 'y'...")
    }
    let body = EditorTextView.make()
    body.load("text")
    #expect(body.usesFindBar && body.isIncrementalSearchingEnabled)
    let font = body.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
    #expect(font?.pointSize == 16)
}

@MainActor @Test func bodyKeepsAReadingMeasure() {
    let tv = EditorTextView.make()
    tv.setFrameSize(NSSize(width: 1000, height: 600))
    #expect(tv.textContainerInset.width == 220)   // (1000 - 560) / 2
    tv.setFrameSize(NSSize(width: 500, height: 600))
    #expect(tv.textContainerInset.width == 40)    // never less than the 40 px margin
}

@MainActor @Test func titleHeightGrowsWithWrapping() {
    let one = TitleEditor.height(of: "Short", width: 600)
    let two = TitleEditor.height(of: "Weather station build and other long words", width: 400)
    #expect(one == 60)
    #expect(two >= 112)
    #expect(TitleEditor.height(of: "", width: 600) == 60)
}

@MainActor @Test func titleHeightIsBoundedForTinyWidthsAndLongTitles() {
    #expect(TitleEditor.height(of: "Weather station build", width: 0) == 60)
    #expect(TitleEditor.height(of: String(repeating: "word ", count: 200), width: 600) == CGFloat(216))
}

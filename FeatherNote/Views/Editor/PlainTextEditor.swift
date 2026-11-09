import AppKit
import SwiftUI

/// An NSTextView that never rewrites what the person types, keeps a 560 px reading measure, and draws a placeholder.
final class FeatherTextView: NSTextView {
    var placeholder = ""
    var placeholderFont: NSFont?
    var measure: CGFloat = 560
    var minimumSideInset: CGFloat = 40
    var verticalInset: CGFloat = 0
    /// Called on Return in single-line mode (the title).
    var onReturn: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(minimumSideInset, ((newSize.width - measure) / 2).rounded(.down))
        if textContainerInset.width != side || textContainerInset.height != verticalInset {
            textContainerInset = NSSize(width: side, height: verticalInset)
        }
    }

    override func insertNewline(_ sender: Any?) {
        if let onReturn { onReturn() } else { super.insertNewline(sender) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: placeholderFont ?? font ?? NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// Turns off every automatic change macOS can make to typed text.
    func disableSubstitutions() {
        isRichText = false
        importsGraphics = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        allowsUndo = true
    }

    static func paragraphStyle(lineHeight: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        return p
    }

    func applyTypography(font: NSFont, lineHeight: CGFloat, color: NSColor) {
        self.font = font
        textColor = color
        let style = Self.paragraphStyle(lineHeight: lineHeight)
        defaultParagraphStyle = style
        typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: style,
                            .baselineOffset: (lineHeight - font.ascender + font.descender) / 4]
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
    }
}

/// Shared coordinator: pushes edits out, and replaces the text only when the model's value really changed.
final class TextViewCoordinator: NSObject, NSTextViewDelegate {
    var onChange: (String) -> Void
    init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        onChange(tv.string)
    }
}

extension FeatherTextView {
    /// Sets the text if it differs byte for byte, keeping the selection where possible.
    func setTextIfChanged(_ text: String) {
        guard !string.utf8.elementsEqual(text.utf8) else { return }
        let selection = selectedRange()
        string = text
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        let length = (text as NSString).length
        setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        undoManager?.removeAllActions(withTarget: textStorage as Any)
        needsDisplay = true
    }
}

/// The note body: plain Markdown in a scrolling text view (Phase 4 replaces it with live preview).
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var placeholder: String = "Start writing…"

    static func makeTextView() -> FeatherTextView {
        let tv = FeatherTextView(frame: .zero)
        tv.disableSubstitutions()
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.verticalInset = 8
        tv.applyTypography(font: Theme.bodyNSFont(), lineHeight: 25.6, color: Theme.textBodyNS)
        tv.insertionPointColor = Theme.accentNS
        tv.setAccessibilityLabel("Note body")
        tv.setAccessibilityIdentifier("note-body")
        return tv
    }

    func makeCoordinator() -> TextViewCoordinator { TextViewCoordinator { _ in } }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = Self.makeTextView()
        tv.placeholder = placeholder
        tv.delegate = context.coordinator
        scroll.documentView = tv
        tv.setTextIfChanged(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = { text = $0 }
        guard let tv = scroll.documentView as? FeatherTextView else { return }
        tv.isEditable = isEditable
        tv.placeholder = placeholder
        tv.setTextIfChanged(text)
    }
}

/// The note title: one line, serif 44, same no-substitution rules as the body. Return moves to the body.
struct TitleEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    /// True for a new note: take keyboard focus, then call `onFocused`.
    var wantsFocus = false
    var onFocused: () -> Void = {}

    static func makeTextView() -> FeatherTextView {
        let tv = FeatherTextView(frame: .zero)
        tv.disableSubstitutions()
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineBreakMode = .byWordWrapping
        tv.measure = .greatestFiniteMagnitude   // the header around it already sets the measure
        tv.minimumSideInset = 0
        tv.placeholder = "Title"
        tv.applyTypography(font: Theme.titleNSFont(), lineHeight: 52, color: NSColor(Theme.textPrimary))
        tv.insertionPointColor = Theme.accentNS
        tv.setAccessibilityLabel("Note title")
        tv.setAccessibilityIdentifier("note-title")
        return tv
    }

    func makeCoordinator() -> TextViewCoordinator { TextViewCoordinator { _ in } }

    func makeNSView(context: Context) -> FeatherTextView {
        let tv = Self.makeTextView()
        tv.delegate = context.coordinator
        tv.onReturn = { [weak tv] in tv?.window?.selectNextKeyView(nil) }
        tv.setTextIfChanged(text)
        return tv
    }

    func updateNSView(_ tv: FeatherTextView, context: Context) {
        context.coordinator.onChange = { text = $0.replacingOccurrences(of: "\n", with: " ") }
        tv.isEditable = isEditable
        tv.placeholder = isEditable ? "Title" : "Untitled"
        tv.setTextIfChanged(text)
        if wantsFocus {
            // Focus at once when possible, so the first keystrokes after ⌘N land in the title.
            if let window = tv.window, window.makeFirstResponder(tv) {
                let done = onFocused
                DispatchQueue.main.async { done() }
            } else {
                Self.focus(tv, attempts: 20, then: onFocused)
            }
        }
    }

    /// Makes `tv` first responder once it is in a window (a new title view may not be yet), then calls `done`.
    private static func focus(_ tv: FeatherTextView, attempts: Int, then done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) {
            if let window = tv.window, window.makeFirstResponder(tv) {
                done()
            } else if attempts > 0 {
                focus(tv, attempts: attempts - 1, then: done)
            } else {
                done()
            }
        }
    }

    /// Tall enough for the wrapped title (it wraps rather than truncating, as on the board).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: FeatherTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 560
        return CGSize(width: width, height: Self.height(of: text, width: width))
    }

    /// Height of the wrapped title at `width`: whole 52 px lines, one to four.
    /// SwiftUI also probes with tiny or zero widths; those measure at the 560 px measure so the
    /// title never reports a runaway height that would push the window content around.
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let usable = width < 200 ? 560 : width
        let padding: CGFloat = 10   // lineFragmentPadding on both sides
        let attributes = makeTextView().typingAttributes
        let rect = ((text.isEmpty ? "Title" : text) as NSString).boundingRect(
            with: NSSize(width: usable - padding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: attributes)
        let lines = min(4, max(1, (rect.height / 52).rounded(.up)))
        return lines * 52 + 8
    }
}

import AppKit
import SwiftUI

/// The live-preview editor for SwiftUI. Load a different note by changing `noteID`.
public struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var noteID: AnyHashable
    var mode: EditorMode
    var isEditable: Bool
    var placeholder: String
    var resolveAttachment: (String) -> URL?
    var importFiles: ([URL]) async -> [String]
    var openLink: (String) -> Void
    var theme: EditorTheme

    public init(text: Binding<String>, noteID: AnyHashable, mode: EditorMode, isEditable: Bool, placeholder: String = "Start writing…",
                resolveAttachment: @escaping (String) -> URL? = { _ in nil },
                importFiles: @escaping ([URL]) async -> [String] = { _ in [] },
                openLink: @escaping (String) -> Void = { url in if let u = URL(string: url) { NSWorkspace.shared.open(u) } },
                theme: EditorTheme = .standard) {
        _text = text
        self.noteID = noteID
        self.mode = mode
        self.isEditable = isEditable
        self.placeholder = placeholder
        self.resolveAttachment = resolveAttachment
        self.importFiles = importFiles
        self.openLink = openLink
        self.theme = theme
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void = { _ in }
        var noteID: AnyHashable?

        public func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            onChange(tv.string)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = EditorTextView.make()
        tv.delegate = context.coordinator
        scroll.documentView = tv
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? EditorTextView else { return }
        context.coordinator.onChange = { text = $0 }
        tv.theme = theme
        tv.placeholder = placeholder
        tv.isEditable = isEditable
        tv.openLink = openLink
        tv.resolveAttachment = resolveAttachment
        tv.importFiles = importFiles
        if context.coordinator.noteID != noteID {
            context.coordinator.noteID = noteID
            tv.load(text)
        } else if !tv.string.utf8.elementsEqual(text.utf8) {
            tv.load(text)   // changed outside the editor
        }
        if tv.mode != mode { tv.mode = mode }
    }
}

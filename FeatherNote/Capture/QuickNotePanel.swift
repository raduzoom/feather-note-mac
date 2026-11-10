import AppKit
import FeatherCore
import SwiftUI

/// The floating Quick Note window (board `desktop-quick-note`): a text area, a notebook pop-up and Save Note (⌘↩).
/// Esc closes it without saving.
@MainActor
enum QuickNotePanel {
    private static var panel: NSPanel?

    static func show(model: AppModel) {
        if let panel {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let p = EscapablePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = "Quick Note"
        p.identifier = NSUserInterfaceItemIdentifier("quick-note")
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentViewController = NSHostingController(rootView: QuickNoteView(model: model) { close() })
        p.setContentSize(NSSize(width: 440, height: 260))
        p.center()
        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}

private final class EscapablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { QuickNotePanel.close() }
}

private struct QuickNoteView: View {
    let model: AppModel
    let done: () -> Void
    @State private var text = ""
    @State private var notebookID: ULID?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            QuickNoteTextView(text: $text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: Spacing.s16) {
                Picker("Notebook", selection: $notebookID) {
                    Text("No Notebook").tag(ULID?.none)
                    ForEach(model.notebooks) { Text($0.name).tag(ULID?.some($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("⌘↩").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                Button("Save Note") {
                    let text = self.text, notebook = notebookID
                    Task {
                        if await model.saveQuickNote(text: text, notebookID: notebook) != nil { done() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.s16)
        .onAppear { notebookID = model.quickNoteNotebookID }
    }
}

/// A plain text view with every macOS substitution off, like the editor.
private struct QuickNoteTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> TextViewCoordinator { TextViewCoordinator { _ in } }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = Theme.bodyNSFont()
        tv.textColor = Theme.textBodyNS
        tv.drawsBackground = false
        scroll.drawsBackground = false
        tv.setAccessibilityIdentifier("quick-note-text")
        tv.delegate = context.coordinator
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = { text = $0 }
    }
}

import AppKit

/// The menu bar extra (board `desktop-menu-bar`): New Quick Note, Open FeatherMark, a status line, Quit.
/// "Sync with Feather Cloud…" joins it in Phase 8.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let openMain: () -> Void
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(model: AppModel, openMain: @escaping () -> Void) {
        self.model = model
        self.openMain = openMain
        super.init()
        item.button?.image = NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: "FeatherMark")
        item.button?.setAccessibilityIdentifier("feather-menu-bar")
        let menu = NSMenu()
        menu.delegate = self
        let quick = NSMenuItem(title: "New Quick Note", action: #selector(newQuickNote), keyEquivalent: "n")
        quick.keyEquivalentModifierMask = [.command, .option]
        quick.target = self
        menu.addItem(quick)
        let open = NSMenuItem(title: "Open FeatherMark", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FeatherMark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        updateStatus()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateStatus() }

    private func updateStatus() {
        status.title = Self.statusLine(noteCount: model.noteCount)
    }

    static func statusLine(noteCount: Int) -> String {
        "Local only · \(noteCount.formatted()) \(noteCount == 1 ? "note" : "notes")"
    }

    @objc private func newQuickNote() { QuickNotePanel.show(model: model) }
    @objc private func openApp() { openMain() }
}

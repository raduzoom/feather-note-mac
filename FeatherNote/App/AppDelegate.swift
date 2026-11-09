import AppKit
import FeatherCore
import SwiftUI

/// Opens the library and the one main window.
///
/// The main window is created here with AppKit rather than as a SwiftUI `Window` scene: SwiftUI only opens
/// its scene when the app is launched through LaunchServices, so a direct launch (XCUITest, a shell) showed
/// no window at all. Hosting the SwiftUI view in our own NSWindow behaves the same however the app starts.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let opened: Result<AppModel, Error>
    let dialogs = Dialogs()
    private var window: NSWindow?

    var model: AppModel? { try? opened.get() }

    override init() {
        opened = Result { try AppModel.open(at: LibraryLocation.directory()) }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Saves the note being edited before the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            await model.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func showMainWindow() {
        if window == nil { window = makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let root: AnyView
        switch opened {
        case .success(let model):
            root = AnyView(MainWindow(model: model, dialogs: dialogs).preferredColorScheme(Self.colorSchemeOverride()))
        case .failure(let error):
            root = AnyView(LibraryOpenFailure(error: error))
        }
        let host = NSHostingController(rootView: root)
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.title = "Feather Note"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden   // the board shows no window title
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("FeatherNoteMainWindow")
        window.delegate = self
        return window
    }

    /// `-FeatherColorScheme light|dark`, for tests and screenshots only.
    static func colorSchemeOverride(arguments: [String] = CommandLine.arguments) -> ColorScheme? {
        guard let i = arguments.firstIndex(of: "-FeatherColorScheme"), i + 1 < arguments.count else { return nil }
        switch arguments[i + 1] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Leaving the window (another app, another window) saves the open note.
    func windowDidResignKey(_ notification: Notification) {
        guard let model else { return }
        Task { await model.flush() }
    }
}

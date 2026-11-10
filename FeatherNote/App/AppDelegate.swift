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
    private var menuBar: MenuBarController?
    private var services: ServicesProvider?

    var model: AppModel? { try? opened.get() }

    /// A unit-test host, or a launch on another library (UI tests, screenshots): keep away from the real app's
    /// settings, global shortcut and Share hand-offs.
    let isolated = AppDelegate.isIsolatedRun()

    override init() {
        let isolated = AppDelegate.isIsolatedRun()
        opened = Result {
            try AppModel.open(at: LibraryLocation.directory(),
                              defaults: isolated ? UserDefaults(suiteName: "app.feathernote.FeatherNote.isolated")! : .standard)
        }
        super.init()
    }

    static func isIsolatedRun(arguments: [String] = CommandLine.arguments,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        arguments.contains(LibraryLocation.overrideArgument)
            || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
        if let model {
            menuBar = MenuBarController(model: model) { [weak self] in self?.showMainWindow() }
            if !isolated { model.registerQuickNoteShortcut { QuickNotePanel.show(model: model) } }
            services = ServicesProvider(model: model)
            NSApp.servicesProvider = services
            NSUpdateDynamicServices()
            Task { await model.drainInbox() }
        }
        addContinuityCameraItem()
        // SwiftUI rebuilds the Note menu whenever its content changes (opening a note does): put the item back
        // as soon as it's removed, and again whenever the menu bar opens
        for name in [NSMenu.didRemoveItemNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.addContinuityCameraItem() }
            }
        }
    }

    /// Note › Import from iPhone or iPad: macOS fills in Take Photo, Scan Documents and Add Sketch, and delivers the
    /// result to the editor (EditorTextView.validRequestor).
    private func addContinuityCameraItem() {
        guard let note = NSApp.mainMenu?.items.first(where: { $0.title == "Note" })?.submenu,
              !note.items.contains(where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier }) else { return }
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        note.insertItem(item, at: min(2, note.numberOfItems))   // after New Quick Note and its divider
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model else { return }
        Task { await model.drainInbox() }
    }

    /// `feathernote://inbox?id=…`: the Share extension left a capture; collect it. An isolated run ignores these,
    /// so a test host can never take a real capture into a throwaway library.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model, !isolated else { return }
        for id in urls.compactMap(InboxHandOff.captureID(in:)) {
            Task { await model.collectHandOff(id: id) }
        }
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

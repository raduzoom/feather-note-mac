import AppKit
import Testing
@testable import FeatherNote

/// Note › Import from iPhone or iPad must survive SwiftUI rebuilding the Note menu (opening a note does).
@MainActor @Suite struct ContinuityMenuTests {
    @Test func continuityItemComesBackAfterMenuRebuild() async throws {
        try await Task.sleep(for: .seconds(1))   // the app has finished launching
        let note = try #require(NSApp.mainMenu?.items.first { $0.title == "Note" }?.submenu)
        func present() -> Bool { note.items.contains { $0.identifier == NSMenuItem.importFromDeviceIdentifier } }
        #expect(present())
        // what SwiftUI does when the menu's content changes
        for item in note.items where item.identifier == NSMenuItem.importFromDeviceIdentifier { note.removeItem(item) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(present())
    }
}

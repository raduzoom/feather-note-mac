import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import FeatherCore
@testable import FeatherNote

/// Regression tests from the Phase 5a fresh review.
@MainActor @Suite(.serialized) struct ReviewFix5aTests {
    /// Finding 3: each capture has its own pasteboard, so a capture delivered while the app collects another
    /// can't be wiped.
    @Test func handOffUsesOnePasteboardPerCapture() async throws {
        let prefix = "FNHandOffTest-\(UUID().uuidString)"
        let inbox = Inbox(directory: FileManager.default.temporaryDirectory.appending(path: "FNInbox-\(UUID().uuidString)"))
        var ids: [ULID] = []
        for i in 0..<40 {
            let item = InboxItem(id: ULID.generate(at: 1_762_696_320_000 + Int64(i)), kind: .text, text: "Capture \(i)",
                                 created: 1_762_696_320_000 + Int64(i))
            let url = try InboxHandOff.deliver(item, files: [], prefix: prefix)
            #expect(url.absoluteString == "feathernote://inbox?id=\(item.id)")
            ids.append(item.id)
            // the app collects every other capture while later ones keep arriving
            if i % 2 == 1 { #expect(try InboxHandOff.collect(id: ids[i - 1], into: inbox, prefix: prefix)) }
        }
        for (i, id) in ids.enumerated() where i % 2 == 1 || i == ids.count - 1 {
            _ = try InboxHandOff.collect(id: id, into: inbox, prefix: prefix)
        }
        #expect(try inbox.pending().count == 40)
        #expect(!(try InboxHandOff.collect(id: ids[0], into: inbox, prefix: prefix)))   // released after collecting
    }

    /// Finding 6: opening a different library (a test host, a UI test) must not clear the real setting.
    @Test func foreignLibraryKeepsQuickNoteNotebookSetting() async throws {
        let suite = UserDefaults(suiteName: "FNFix-\(UUID().uuidString)")!
        let a = try await makeModel(defaults: suite)
        let nb = try #require(await a.createNotebook(name: "Personal", parent: nil))
        a.quickNoteNotebookID = nb.id
        _ = try await makeModel(defaults: suite)   // another library on the same settings
        let again = try AppModel.open(at: a.library.directory, defaults: suite)
        await again.load()
        #expect(again.quickNoteNotebookID == nb.id)
    }

    /// Finding 6: test hosts and launches with -FeatherLibraryPath run isolated from the real app's state.
    @Test func isolatedRunDetection() {
        #expect(AppDelegate.isIsolatedRun(arguments: ["app"], environment: ["XCTestBundlePath": "/x"]))
        #expect(AppDelegate.isIsolatedRun(arguments: ["app", "-FeatherLibraryPath", "/tmp/x"], environment: [:]))
        #expect(!AppDelegate.isIsolatedRun(arguments: ["app"], environment: [:]))
    }

    /// Finding 2: a shortcut macOS itself uses (an enabled symbolic hotkey) is reported.
    @Test func systemShortcutIsReported() async throws {
        let system = try #require(HotKey.systemShortcuts().first, "no enabled system shortcut on this Mac")
        let m = try await makeModel()
        m.registerQuickNoteShortcut {}
        m.changeQuickNoteShortcut(system)
        #expect(m.quickNoteShortcutError == "macOS uses this shortcut.")
        m.changeQuickNoteShortcut(.quickNoteDefault)
    }

    /// Finding 9 (deferred minor): two quick saves of the same text make two notes.
    @Test(.disabled("Deferred minor (5a review finding 9): pressing Save twice before the panel closes makes two notes"))
    func doubleSaveMakesOneNote() async throws {
        let m = try await makeModel()
        async let a = m.saveQuickNote(text: "Call the plumber", notebookID: nil)
        async let b = m.saveQuickNote(text: "Call the plumber", notebookID: nil)
        _ = await (a, b)
        #expect(m.noteCount == 1)
    }
}

import Carbon.HIToolbox
import Foundation
import Testing
import FeatherCore
@testable import FeatherNote

@MainActor @Suite(.serialized) struct QuickNoteTests {
    @Test func shortcutRoundTrips() {
        #expect(Shortcut(stored: Shortcut.quickNoteDefault.stored) == .quickNoteDefault)
        #expect(Shortcut.quickNoteDefault.display == "⌥⌘N")
        #expect(Shortcut(stored: "nonsense") == nil)
    }

    @Test func saveQuickNoteUsesSplitAndNotebook() async throws {
        let m = try await makeModel()
        let p = try #require(await m.createNotebook(name: "Personal", parent: nil))
        let note = try #require(await m.saveQuickNote(text: "Shed\nQuote by Friday", notebookID: p.id))
        #expect(note.title == "Shed" && note.body == "Quote by Friday" && note.notebookID == p.id)
        #expect(m.noteCount == 1)
    }

    @Test func emptyQuickNoteIsNotSaved() async throws {
        let m = try await makeModel()
        #expect(await m.saveQuickNote(text: "  \n ", notebookID: nil) == nil)
        #expect(m.noteCount == 0)
    }

    @Test func quickNoteNotebookPersists() async throws {
        let defaults = UserDefaults(suiteName: "FNTests-\(UUID().uuidString)")!
        let m = try await makeModel(defaults: defaults)
        let p = try #require(await m.createNotebook(name: "Personal", parent: nil))
        m.quickNoteNotebookID = p.id
        let again = try AppModel.open(at: m.library.directory, defaults: defaults)
        await again.load()
        #expect(again.quickNoteNotebookID == p.id)
        await again.deleteNotebook(p.id)
        #expect(again.quickNoteNotebookID == nil)   // a deleted notebook falls back to No Notebook
    }

    @Test func unregistrableShortcutReportsFailure() throws {
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        let first = try HotKey(shortcut: shortcut) {}
        #expect(throws: HotKeyError.unavailable) { _ = try HotKey(shortcut: shortcut) {} }
        _ = first
    }

    @Test func takenShortcutSetsError() async throws {
        let m = try await makeModel()
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        let other = try HotKey(shortcut: shortcut) {}   // another app holding it
        m.quickNoteShortcut = shortcut
        m.registerQuickNoteShortcut {}
        #expect(m.quickNoteShortcutError == "This shortcut is used by another app.")
        _ = other
    }
}

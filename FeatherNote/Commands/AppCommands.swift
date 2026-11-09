import FeatherCore
import SwiftUI

/// The menu bar (plan Task 9). Every action calls AppModel.
struct AppCommands: Commands {
    let model: AppModel?
    let dialogs: Dialogs
    let showWindow: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .newItem) {
            Button("New Note") { act { await $0.newNote() } }
                .keyboardShortcut("n")
            Button("New Notebook") {
                guard let model else { return }
                showWindow()
                dialogs.askName(title: "New Notebook", placeholder: "Name", button: "Create") { name in
                    if let nb = await model.createNotebook(name: name, parent: nil) { await model.select(.notebook(nb.id)) }
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Notes…") { if let model { FileActions.importNotes(model: model, dialogs: dialogs) } }
            Button("Export Notes…") { if let model { FileActions.exportNotes(model: model, dialogs: dialogs, notebook: nil) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Notebook…") {
                if let model, case .notebook(let id) = model.selection { FileActions.exportNotes(model: model, dialogs: dialogs, notebook: id) }
            }
            .disabled(!notebookSelected)
        }
        CommandMenu("Note") {
            if let model, let e = model.editor {
                if e.isTrashed {
                    Button("Restore Note") { act { await $0.restore(e.id) } }
                    Button("Delete Permanently…") {
                        dialogs.confirm(Formatting.deletePermanentlyConfirmation(title: e.title)) { await model.deletePermanently(e.id) }
                    }
                } else {
                    Button(e.pinned ? "Unpin Note" : "Pin Note") { act { await $0.togglePin(e.id) } }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                    MoveMenu(model: model, noteID: e.id)
                    TagsMenu(model: model, dialogs: dialogs, noteID: e.id)
                    Divider()
                    // No shortcut here: a menu ⌘⌫ would fire while typing. The note list handles Delete itself.
                    Button("Move to Trash") { act { await $0.trash(e.id) } }
                }
            } else {
                Button("Pin Note") {}.disabled(true)
                Button("Move to Trash") {}.disabled(true)
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Search Notes") { model?.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandGroup(before: .sidebar) {
            Button(model?.editorMode == .raw ? "Show Live Preview" : "Show Markdown") { model?.toggleEditorMode() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button("All Notes") { act { await $0.select(.all) } }.keyboardShortcut("1")
            Button("Recent") { act { await $0.select(.recent) } }.keyboardShortcut("2")
            Button("Pinned") { act { await $0.select(.pinned) } }.keyboardShortcut("3")
            Button("Trash") { act { await $0.select(.trash) } }.keyboardShortcut("4")
            Divider()
        }
    }

    private var notebookSelected: Bool {
        if let model, case .notebook = model.selection { return true }
        return false
    }

    private func act(_ body: @escaping @MainActor (AppModel) async -> Void) {
        guard let model else { return }
        Task { await body(model) }
    }
}

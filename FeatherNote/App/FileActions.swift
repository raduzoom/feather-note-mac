import AppKit
import FeatherCore

/// Import and export through the system open panel.
@MainActor
enum FileActions {
    /// File › Import Notes…: the import sheet's source picker (Evernote, Notion, Markdown folder).
    static func importNotes(model: AppModel, dialogs: Dialogs) {
        guard model.importState == nil else { return }
        model.showImportSource = true
    }

    static func importSummary(_ r: ImportReport) -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        var lines = ["Imported \(n(r.notes, "note", "notes")) and \(n(r.attachments, "attachment", "attachments"))."]
        if !r.skipped.isEmpty {
            lines.append("Skipped \(n(r.skipped.count, "file", "files")):")
            for s in r.skipped.prefix(20) {
                lines.append("• \(s.path) (\(s.reason == .notUTF8 ? "not UTF-8 text" : "not used by any note"))")
            }
            if r.skipped.count > 20 { lines.append("…and \(r.skipped.count - 20) more.") }
        }
        return lines.joined(separator: "\n")
    }

    static func exportNotes(model: AppModel, dialogs: Dialogs, notebook: ULID?) {
        let panel = NSOpenPanel()
        panel.title = notebook == nil ? "Export Notes" : "Export Notebook"
        panel.message = "Choose where to put the exported folder. Nothing in it will be overwritten."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let r = await model.export(to: url, notebook: notebook) else { return }
            let notes = "\(r.notes) \(r.notes == 1 ? "note" : "notes")"
            dialogs.show(title: "Export finished", body: "Exported \(notes) to “\(r.root.lastPathComponent)”.")
            NSWorkspace.shared.activateFileViewerSelecting([r.root])
        }
    }
}

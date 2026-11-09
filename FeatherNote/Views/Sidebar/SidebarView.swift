import FeatherCore
import SwiftUI

/// A notebook with its children, for the outline.
struct NotebookNode: Identifiable {
    let notebook: Notebook
    let children: [NotebookNode]?
    var id: ULID { notebook.id }

    static func tree(_ notebooks: [Notebook]) -> [NotebookNode] {
        let byParent = Dictionary(grouping: notebooks, by: \.parentID)
        func build(_ parent: ULID?) -> [NotebookNode] {
            (byParent[parent] ?? []).map { nb in
                let kids = build(nb.id)
                return NotebookNode(notebook: nb, children: kids.isEmpty ? nil : kids)
            }
        }
        return build(nil)
    }
}

/// Drag payloads between the list and the sidebar.
enum DragPayload {
    static func note(_ id: ULID) -> String { "note:\(id)" }
    static func notebook(_ id: ULID) -> String { "notebook:\(id)" }
    static func parse(_ s: String) -> (kind: String, id: ULID)? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = ULID(string: String(parts[1])) else { return nil }
        return (String(parts[0]), id)
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    var dialogs: Dialogs

    var body: some View {
        List(selection: Binding<SidebarItem?>(get: { model.selection }, set: { item in
            if let item { Task { await model.select(item) } }
        })) {
            Section {
                viewRow("All Notes", "tray.full", .all, count: model.counts.all)
                    .dropDestination(for: String.self) { items, _ in dropNotes(items) { await model.move($0, to: nil) } }
                viewRow("Recent", "clock", .recent, count: nil)
                viewRow("Pinned", "star", .pinned, count: model.counts.pinned)
                viewRow("Trash", "trash", .trash, count: model.counts.trash)
            }

            Section {
                OutlineGroup(NotebookNode.tree(model.notebooks), children: \.children) { node in
                    notebookRow(node.notebook)
                }
            } header: {
                HStack {
                    Text("Notebooks")
                    Spacer()
                    Button { newNotebook(parent: nil) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New Notebook")
                        .accessibilityLabel("New Notebook")
                }
                .dropDestination(for: String.self) { items, _ in
                    dropNotebooks(items) { await model.moveNotebook($0, to: nil) }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in tagRow(tag) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            Button { Task { await model.newNote() } } label: {
                Label("New Note", systemImage: "square.and.pencil")
                    .font(Theme.uiLabelStrong)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .foregroundStyle(Theme.accentOnTint)
                    .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.s16)
            .padding(.vertical, Spacing.s8)
            .help("New Note (⌘N)")
        }
    }

    private func viewRow(_ title: String, _ icon: String, _ item: SidebarItem, count: Int?) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if let count, count > 0 { Text("\(count)").foregroundStyle(Theme.textSecondary).monospacedDigit() }
            }
        } icon: { Image(systemName: icon) }
        .tag(item)
        .accessibilityLabel(count.map { "\(title), \($0) \($0 == 1 ? "note" : "notes")" } ?? title)
    }

    private func notebookRow(_ nb: Notebook) -> some View {
        let count = model.counts.notebooks[nb.id, default: 0]
        return Label {
            HStack {
                Text(nb.name)
                Spacer()
                if count > 0 { Text("\(count)").foregroundStyle(Theme.textSecondary).monospacedDigit() }
            }
        } icon: { Image(systemName: "folder") }
        .tag(SidebarItem.notebook(nb.id))
        .accessibilityLabel("\(nb.name), \(count) \(count == 1 ? "note" : "notes")")
        .draggable(DragPayload.notebook(nb.id))
        .dropDestination(for: String.self) { items, _ in
            var handled = false
            for item in items {
                guard let p = DragPayload.parse(item) else { continue }
                handled = true
                Task {
                    if p.kind == "note" { await model.move(p.id, to: nb.id) }
                    if p.kind == "notebook", p.id != nb.id { await model.moveNotebook(p.id, to: nb.id) }
                }
            }
            return handled
        }
        .contextMenu {
            Button("New Notebook Inside…") { newNotebook(parent: nb.id) }
            Button("Rename…") {
                dialogs.askName(title: "Rename Notebook", placeholder: "Name", initial: nb.name, button: "Rename") {
                    await model.renameNotebook(nb.id, to: $0)
                }
            }
            Button("Export Notebook…") { FileActions.exportNotes(model: model, dialogs: dialogs, notebook: nb.id) }
            Divider()
            Button("Delete Notebook…", role: .destructive) { confirmDelete(nb) }
        }
    }

    private func tagRow(_ tag: Tag) -> some View {
        Label(tag.name, systemImage: "number")
            .tag(SidebarItem.tag(tag.id))
            .accessibilityLabel("Tag \(tag.name)")
            .dropDestination(for: String.self) { items, _ in
                dropNotes(items) { id in
                    let current = try? await model.library.note(id)?.tagIDs
                    await model.setTags(id, (current ?? []).union([tag.id]))
                }
            }
            .contextMenu {
                Button("Rename…") {
                    dialogs.askName(title: "Rename Tag", placeholder: "Name", initial: tag.name, button: "Rename") {
                        await model.renameTag(tag.id, to: $0)
                    }
                }
                Button("Delete Tag…", role: .destructive) {
                    dialogs.confirm(.init(title: "Delete the tag “\(tag.name)”?",
                                          message: "Notes keep their text; only the tag is removed.",
                                          button: "Delete Tag")) {
                        await model.deleteTag(tag.id)
                    }
                }
            }
    }

    private func newNotebook(parent: ULID?) {
        dialogs.askName(title: parent == nil ? "New Notebook" : "New Notebook Inside", placeholder: "Name", button: "Create") { name in
            if let nb = await model.createNotebook(name: name, parent: parent) { await model.select(.notebook(nb.id)) }
        }
    }

    private func confirmDelete(_ nb: Notebook) {
        let c = Formatting.deleteNotebookConfirmation(name: nb.name, subNotebooks: model.subNotebookCount(of: nb.id),
                                                      notes: model.counts.notebooks[nb.id, default: 0])
        dialogs.confirm(c) { await model.deleteNotebook(nb.id) }
    }

    private func dropNotes(_ items: [String], _ action: @escaping (ULID) async -> Void) -> Bool {
        let ids = items.compactMap(DragPayload.parse).filter { $0.kind == "note" }.map(\.id)
        Task { for id in ids { await action(id) } }
        return !ids.isEmpty
    }

    private func dropNotebooks(_ items: [String], _ action: @escaping (ULID) async -> Void) -> Bool {
        let ids = items.compactMap(DragPayload.parse).filter { $0.kind == "notebook" }.map(\.id)
        Task { for id in ids { await action(id) } }
        return !ids.isEmpty
    }
}

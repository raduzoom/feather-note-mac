import FeatherCore
import SwiftUI

/// The middle column: header, search filters, rows, and the list's empty states.
struct NoteListView: View {
    @Bindable var model: AppModel
    var dialogs: Dialogs
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isSearching { filters }
            content
        }
        .background(Theme.glassList)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
    }

    /// The board puts search at the top of the list column, not in the window toolbar.
    private var searchField: some View {
        HStack(spacing: Spacing.s8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            TextField("Search notes", text: Binding(get: { model.searchText }, set: { model.typeSearch($0) }))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search notes")
                .onExitCommand { model.typeSearch("") }
            if !model.searchText.isEmpty {
                Button { model.typeSearch("") } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .font(Theme.uiLabel)
        .padding(.horizontal, Spacing.s8)
        .frame(height: 32)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            searchField
                .padding(.bottom, Spacing.s8)
            Text(model.selectionTitle)
                .font(Theme.panelTitle)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if model.selection == .trash {
                HStack {
                    Text("Deleted notes are removed after \(model.trashRetentionDays) days.")
                        .font(Theme.meta)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if model.counts.trash > 0 {
                        Button("Empty Trash…") {
                            dialogs.confirm(Formatting.emptyTrashConfirmation(count: model.counts.trash)) { await model.emptyTrash() }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.s24)
        .padding(.top, Spacing.s16)
        .padding(.bottom, Spacing.s8)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(spacing: Spacing.s8) {
                if let id = model.searchNotebookID, let name = model.notebookName(id) {
                    chip(name, remove: "Remove filter: notebook \(name)") { Task { await model.setSearchNotebook(nil) } }
                }
                ForEach(model.tags.filter { model.searchTagIDs.contains($0.id) }) { tag in
                    chip("#\(tag.name)", remove: "Remove filter: tag \(tag.name)") { Task { await model.toggleSearchTag(tag.id) } }
                }
                Menu("Add Filter") {
                    Menu("Notebook") {
                        ForEach(model.notebooks) { nb in
                            Button(nb.name) { Task { await model.setSearchNotebook(nb.id) } }
                        }
                    }
                    Menu("Tag") {
                        ForEach(model.tags) { tag in
                            Toggle("#\(tag.name)", isOn: Binding(get: { model.searchTagIDs.contains(tag.id) },
                                                                 set: { _ in Task { await model.toggleSearchTag(tag.id) } }))
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            let count = model.searchHits?.count ?? 0
            Text("\(count) \(count == 1 ? "result" : "results")")
                .font(Theme.meta)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Spacing.s24)
        .padding(.bottom, Spacing.s8)
    }

    private func chip(_ label: String, remove: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.s4) {
                Text(label)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .font(Theme.meta.weight(.semibold))
            .foregroundStyle(Theme.accentOnTint)
            .padding(.horizontal, Spacing.s8)
            .frame(height: 24)
            .background(Theme.accentTint, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(remove)
    }

    @ViewBuilder private var content: some View {
        switch model.emptyState {
        case .firstLaunch:
            EmptyStateView(title: "", message: "Your notes will appear here.")
        case .emptyView:
            EmptyStateView(title: "Nothing here yet", message: "Press ⌘N to write a note here.")
        case .emptyTrash:
            EmptyStateView(title: "Trash is empty",
                           message: "Notes you delete wait here for \(model.trashRetentionDays) days before they're removed for good.")
        case .noSearchResults(let query, let limitedTo):
            if let limitedTo {
                EmptyStateView(title: "No notes match “\(query)”",
                               message: "You're searching in \(limitedTo) only. Try all notebooks, or fewer words.",
                               secondary: ("Search All Notebooks", { Task { await model.setSearchNotebook(nil) } }))
            } else {
                EmptyStateView(title: "No notes match “\(query)”", message: "Try fewer words, or check the spelling.")
            }
        default:
            list
        }
    }

    private var list: some View {
        List(selection: Binding<ULID?>(get: { model.selectedNoteID }, set: { id in Task { await model.selectNote(id) } })) {
            if let hits = model.searchHits {
                ForEach(hits, id: \.note.id) { hit in
                    row(hit.note, snippet: (hit.snippet, hit.matches))
                }
            } else {
                ForEach(model.notes) { note in row(note, snippet: nil) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            guard let id = model.selectedNoteID else { return }
            if model.selection == .trash {
                let title = model.editor?.title ?? ""
                dialogs.confirm(Formatting.deletePermanentlyConfirmation(title: title)) { await model.deletePermanently(id) }
            } else {
                Task { await model.trash(id) }
            }
        }
    }

    private func row(_ note: NoteSummary, snippet: (text: String, matches: [Range<Int>])?) -> some View {
        NoteRow(summary: note, notebookName: note.notebookID.flatMap(model.notebookName), snippet: snippet,
                trashRetentionDays: model.trashRetentionDays)
            .tag(note.id)
            .draggable(DragPayload.note(note.id))
            .contextMenu { NoteMenu(model: model, dialogs: dialogs, noteID: note.id, pinned: note.pinned, trashed: note.trashedAt != nil) }
    }
}

/// The note actions, shared by the row context menu, the Note menu and the toolbar.
struct NoteMenu: View {
    let model: AppModel
    let dialogs: Dialogs
    let noteID: ULID
    let pinned: Bool
    let trashed: Bool

    var body: some View {
        if trashed {
            Button("Restore Note") { Task { await model.restore(noteID) } }
            Button("Delete Permanently…") {
                let title = model.notes.first { $0.id == noteID }?.title ?? model.editor?.title ?? ""
                dialogs.confirm(Formatting.deletePermanentlyConfirmation(title: title)) { await model.deletePermanently(noteID) }
            }
        } else {
            Button(pinned ? "Unpin Note" : "Pin Note") { Task { await model.togglePin(noteID) } }
            MoveMenu(model: model, noteID: noteID)
            TagsMenu(model: model, dialogs: dialogs, noteID: noteID)
            Divider()
            Button("Move to Trash") { Task { await model.trash(noteID) } }
        }
    }
}

struct MoveMenu: View {
    let model: AppModel
    let noteID: ULID
    var title = "Move To"
    /// Horizontal padding inside the label (the toolbar's glass pills); 0 in menus.
    var labelPadding: CGFloat = 0

    var body: some View {
        Menu {
            Button("No Notebook") { Task { await model.move(noteID, to: nil) } }
            Divider()
            ForEach(flatten(NotebookNode.tree(model.notebooks), depth: 0), id: \.0.id) { nb, depth in
                Button(String(repeating: "    ", count: depth) + nb.name) { Task { await model.move(noteID, to: nb.id) } }
            }
        } label: {
            Text(title).padding(.horizontal, labelPadding)
        }
    }

    private func flatten(_ nodes: [NotebookNode], depth: Int) -> [(Notebook, Int)] {
        nodes.flatMap { [($0.notebook, depth)] + flatten($0.children ?? [], depth: depth + 1) }
    }
}

struct TagsMenu: View {
    let model: AppModel
    let dialogs: Dialogs
    let noteID: ULID
    /// Horizontal padding inside the label (the toolbar's glass pills); 0 in menus.
    var labelPadding: CGFloat = 0

    var body: some View {
        Menu {
            let current = model.tagsByNote[noteID, default: []]
            ForEach(model.tags) { tag in
                Toggle(tag.name, isOn: Binding(get: { current.contains(tag.id) },
                                               set: { _ in Task { await model.toggleTag(tag.id, on: noteID) } }))
            }
            if !model.tags.isEmpty { Divider() }
            Button("New Tag…") {
                dialogs.askName(title: "New Tag", placeholder: "Name", button: "Create") { name in
                    guard let tag = await model.createTag(name: name) else { return }
                    let now = (try? await model.library.note(noteID)?.tagIDs) ?? []
                    await model.setTags(noteID, now.union([tag.id]))
                }
            }
        } label: {
            Text("Tags").padding(.horizontal, labelPadding)
        }
    }
}

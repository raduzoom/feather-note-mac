import FeatherCore
import SwiftUI

/// Three columns over the glass backdrop, plus every alert the app shows.
struct MainWindow: View {
    @Bindable var model: AppModel
    @Bindable var dialogs: Dialogs
    @State private var nameText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, dialogs: dialogs)
                .navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 320)
        } content: {
            NoteListView(model: model, dialogs: dialogs)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            EditorPane(model: model, dialogs: dialogs)
                .toolbar { EditorToolbar(model: model, dialogs: dialogs) }
        }
        .background(GlassBackground())
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 960, minHeight: 600)
        .task {
            await model.load()
            model.startMaintenance()
        }
        .alert(dialogs.name?.title ?? "", isPresented: Binding(get: { dialogs.name != nil }, set: { if !$0 { dialogs.name = nil } }),
               presenting: dialogs.name) { request in
            TextField(request.placeholder, text: $nameText)
            Button(request.button) {
                let name = nameText
                Task { await request.onSubmit(name) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: dialogs.name?.id) { nameText = dialogs.name?.initial ?? "" }
        .alert(dialogs.confirmRequest?.confirmation.title ?? "",
               isPresented: Binding(get: { dialogs.confirmRequest != nil }, set: { if !$0 { dialogs.confirmRequest = nil } }),
               presenting: dialogs.confirmRequest) { request in
            Button(request.confirmation.button, role: .destructive) { Task { await request.onConfirm() } }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.confirmation.message)
        }
        .alert(dialogs.message?.title ?? "", isPresented: Binding(get: { dialogs.message != nil }, set: { if !$0 { dialogs.message = nil } }),
               presenting: dialogs.message) { _ in
            Button("OK") {}
        } message: { message in
            Text(message.body)
        }
        .alert("Couldn't do that", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// Toolbar for the open note: Pinned/Pin, Tags, Move, Markdown (Phase 4), Share.
struct EditorToolbar: ToolbarContent {
    let model: AppModel
    let dialogs: Dialogs

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let e = model.editor, !e.isTrashed {
                Button { Task { await model.togglePin(e.id) } } label: {
                    Label(e.pinned ? "Pinned" : "Pin", systemImage: e.pinned ? "star.fill" : "star")
                }
                .labelStyle(.titleAndIcon)
                .help(e.pinned ? "Unpin Note (⇧⌘P)" : "Pin Note (⇧⌘P)")
                TagsMenu(model: model, dialogs: dialogs, noteID: e.id)
                    .help("Tags")
                MoveMenu(model: model, noteID: e.id, title: "Move")
                    .help("Move to a notebook")
                Button {} label: { Label("Markdown", systemImage: "number") }
                    .labelStyle(.titleAndIcon)
                    .disabled(true)
                    .help("Live preview arrives with the new editor")
                ShareLink(item: share(e)) { Label("Share", systemImage: "square.and.arrow.up") }
                    .labelStyle(.iconOnly)
                    .help("Share note")
                    .accessibilityLabel("Share note")
            }
        }
    }

    private func share(_ e: EditorState) -> String {
        e.title.isEmpty ? e.body : "\(e.title)\n\n\(e.body)"
    }
}

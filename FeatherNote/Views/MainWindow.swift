import FeatherCore
import FeatherEditor
import SwiftUI

/// Three columns over the glass backdrop, plus every alert the app shows.
struct MainWindow: View {
    @Bindable var model: AppModel
    @Bindable var dialogs: Dialogs
    @State private var nameText = ""

    /// `-FeatherImportFixture <path>`: UI tests start an import at launch.
    static func importFixture(arguments: [String] = CommandLine.arguments) -> ImportSource? {
        guard let i = arguments.firstIndex(of: "-FeatherImportFixture"), i + 1 < arguments.count else { return nil }
        return ImportSource(url: URL(fileURLWithPath: arguments[i + 1]))
    }

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
            if let fixture = Self.importFixture() { model.startImport(fixture) }
        }
        .sheet(isPresented: Binding(get: { model.showImportSource || model.importState != nil },
                                    set: { if !$0 { model.showImportSource = false } })) {
            ImportSheet(model: model).interactiveDismissDisabled()
        }
        // dropping an export (.enex, .zip or a folder) outside the editor imports it
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard model.importState == nil, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let source = ImportSource(url: url) else { return }
                Task { @MainActor in model.startImport(source) }
            }
            return true
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
    /// Room inside the glass pills, so labels don't touch their edges.
    static let labelPadding: CGFloat = 6

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let e = model.editor, !e.isTrashed {
                Button { Task { await model.togglePin(e.id) } } label: {
                    Label(e.pinned ? "Pinned" : "Pin", systemImage: e.pinned ? "star.fill" : "star")
                        .padding(.horizontal, Self.labelPadding)
                }
                .labelStyle(.titleAndIcon)
                .help(e.pinned ? "Unpin Note (⇧⌘P)" : "Pin Note (⇧⌘P)")
                TagsMenu(model: model, dialogs: dialogs, noteID: e.id, labelPadding: Self.labelPadding)
                    .help("Tags")
                MoveMenu(model: model, noteID: e.id, title: "Move", labelPadding: Self.labelPadding)
                    .help("Move to a notebook")
                Toggle(isOn: Binding(get: { model.editorMode == .raw }, set: { _ in model.toggleEditorMode() })) {
                    Label("Markdown", systemImage: "number")
                        .padding(.horizontal, Self.labelPadding)
                }
                .toggleStyle(.button)
                .labelStyle(.titleAndIcon)
                .help(model.editorMode == .raw ? "Show Live Preview (⇧⌘M)" : "Show Markdown (⇧⌘M)")
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

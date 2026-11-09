import FeatherCore
import Foundation
import Observation

/// The open note as the editor sees it.
struct EditorState: Equatable {
    var id: ULID
    var title: String
    var body: String
    var isTrashed: Bool
    var notebookID: ULID?
    var tagIDs: Set<ULID>
    var pinned: Bool
    var modified: Int64
    var trashedAt: Int64?

    init(_ note: Note) {
        id = note.id
        title = note.title
        body = note.body
        isTrashed = note.trashedAt != nil
        notebookID = note.notebookID
        tagIDs = note.tagIDs
        pinned = note.pinned
        modified = note.modified
        trashedAt = note.trashedAt
    }
}

/// Owns the library and every piece of UI state. Views read it and call its methods; they hold no behaviour.
@MainActor @Observable
final class AppModel {
    static let retentionKey = "trashRetentionDays"
    static let retentionChoices = [7, 14, 30, 60, 90]

    let library: Library
    let defaults: UserDefaults

    // Sidebar
    private(set) var selection: SidebarItem = .all
    private(set) var notebooks: [Notebook] = []
    private(set) var tags: [Tag] = []
    private(set) var counts = LibraryCounts(all: 0, pinned: 0, trash: 0, notebooks: [:])
    /// Tag ids of every tagged note (for the Tags menu of any row, open or not).
    private(set) var tagsByNote: [ULID: Set<ULID>] = [:]

    // Note list and search
    private(set) var notes: [NoteSummary] = []
    private(set) var searchText = ""
    /// nil when not searching.
    private(set) var searchHits: [SearchHit]?
    private(set) var searchTagIDs: Set<ULID> = []
    private(set) var searchNotebookID: ULID?

    // Editor
    private(set) var selectedNoteID: ULID?
    private(set) var editor: EditorState?

    var lastError: String?
    /// Set by New Note: the title should take keyboard focus once it appears.
    private(set) var titleWantsFocus = false
    func titleTookFocus() { titleWantsFocus = false }
    /// Bumped by Find (⌘F) so the list's search field takes focus.
    private(set) var searchFocusRequest = 0
    func requestSearchFocus() { searchFocusRequest += 1 }

    var trashRetentionDays: Int {
        didSet { defaults.set(trashRetentionDays, forKey: Self.retentionKey) }
    }

    /// Tests only: delays the search for a given query, to provoke out-of-order results.
    var searchDelay: (@Sendable (String) -> Duration)?
    /// How long after the last keystroke an edit is saved.
    var saveDelay: Duration = .milliseconds(500)

    /// The unsaved edit: which note, and its title and body at the last keystroke.
    /// `save()` writes this snapshot, never whatever note `editor` shows by then.
    private struct PendingEdit { var id: ULID; var title: String; var body: String }
    private var pending: PendingEdit?
    /// Bumped by every keystroke, so an await that started before it can tell its data is stale.
    private var editVersion = 0
    private var saveTask: Task<Void, Never>?
    private var runningSave: Task<Void, Never>?
    private var searchGeneration = 0
    private var purgedThisLaunch = false

    private init(library: Library, defaults: UserDefaults) {
        self.library = library
        self.defaults = defaults
        let stored = defaults.integer(forKey: Self.retentionKey)
        trashRetentionDays = stored > 0 ? stored : 30
    }

    static func open(at directory: URL, clock: LibraryClock = .system, defaults: UserDefaults = .standard) throws -> AppModel {
        AppModel(library: try Library.open(at: directory, clock: clock), defaults: defaults)
    }

    // MARK: Derived

    var isSearching: Bool { searchHits != nil }

    /// The ids the note list shows, in order.
    var visibleIDs: [ULID] { searchHits.map { $0.map(\.note.id) } ?? notes.map(\.id) }

    var emptyState: EmptyState? {
        if let hits = searchHits, hits.isEmpty {
            return .noSearchResults(query: searchText, limitedTo: searchNotebookID.flatMap(notebookName))
        }
        if visibleIDs.isEmpty {
            if counts.all == 0 && counts.trash == 0 && selection != .trash { return .firstLaunch }
            return selection == .trash ? .emptyTrash : .emptyView
        }
        return selectedNoteID == nil ? .noNoteSelected : nil
    }

    func notebookName(_ id: ULID) -> String? { notebooks.first { $0.id == id }?.name }
    func tagName(_ id: ULID) -> String? { tags.first { $0.id == id }?.name }

    func subNotebookCount(of id: ULID) -> Int {
        let children = Dictionary(grouping: notebooks, by: \.parentID)
        func count(_ id: ULID) -> Int { (children[id] ?? []).reduce(0) { $0 + 1 + count($1.id) } }
        return count(id)
    }

    var selectionTitle: String {
        switch selection {
        case .all: "My Notes"
        case .recent: "Recent"
        case .pinned: "Pinned"
        case .trash: "Trash"
        case .notebook(let id): notebookName(id) ?? "Notebook"
        case .tag(let id): tagName(id).map { "#\($0)" } ?? "Tag"
        }
    }

    // MARK: Loading

    /// Reloads everything. The first call per launch also empties expired Trash.
    func load() async {
        if !purgedThisLaunch {
            purgedThisLaunch = true
            await purgeExpiredTrash()
        }
        await refresh()
    }

    /// Hourly Trash purge while the app runs.
    func startMaintenance() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                await self.purgeExpiredTrash()
                await self.refresh()
            }
        }
    }

    private func purgeExpiredTrash() async {
        await attempt { _ = try await library.purgeExpiredTrash(retentionDays: trashRetentionDays) }
    }

    /// Reloads sidebar data, the list (or search) and the editor, then fixes the selection.
    private func refresh() async {
        let before = visibleIDs
        await attempt {
            notebooks = try await library.notebooks()
            tags = try await library.tags()
            counts = try await library.counts()
            tagsByNote = try await library.noteTagIDs()
            if case .notebook(let id) = selection, !notebooks.contains(where: { $0.id == id }) { selection = .all }
            if case .tag(let id) = selection, !tags.contains(where: { $0.id == id }) { selection = .all }
            notes = try await library.notes(in: selection.scope)
        }
        if isSearching { await runSearch() }
        await fixSelection(previous: before)
    }

    /// Keeps the selection if it's still visible; otherwise picks the note that took its place, or the one before.
    private func fixSelection(previous: [ULID]) async {
        let visible = visibleIDs
        guard let id = selectedNoteID else { return }
        if visible.contains(id) {
            await reloadEditor()
            return
        }
        var replacement: ULID?
        if let index = previous.firstIndex(of: id), !visible.isEmpty {
            replacement = visible[min(index, visible.count - 1)]
        }
        await openNote(replacement)
    }

    /// Re-reads the open note, unless the person typed since (then their text wins).
    private func reloadEditor() async {
        guard let id = selectedNoteID, pending == nil else { return }
        let version = editVersion
        var fresh: Note?
        await attempt { fresh = try await library.note(id) }
        guard version == editVersion, pending == nil, selectedNoteID == id else { return }
        editor = fresh.map(EditorState.init)
    }

    /// Opens another note (or none). Any unsaved edit is saved first, to the note it belongs to.
    private func openNote(_ id: ULID?) async {
        await flush()
        selectedNoteID = id
        editor = nil
        guard let id else { return }
        var note: Note?
        await attempt { note = try await library.note(id) }
        guard selectedNoteID == id, editor == nil else { return }   // another open won meanwhile
        editor = note.map(EditorState.init)
    }

    // MARK: Sidebar

    func select(_ item: SidebarItem) async {
        await flush()
        selection = item
        clearSearchState()
        await refresh()
    }

    // MARK: Notes

    func selectNote(_ id: ULID?) async {
        await flush()
        await openNote(id)
    }

    func newNote() async {
        await flush()
        var notebookID: ULID?
        var tagIDs: Set<ULID> = []
        switch selection {
        case .notebook(let id): notebookID = id
        case .tag(let id): tagIDs = [id]
        case .trash, .pinned: selection = .all
        case .all, .recent: break
        }
        clearSearchState()
        var created: Note?
        await attempt { created = try await library.createNote(notebookID: notebookID, tagIDs: tagIDs) }
        await refresh()
        if let created {
            await openNote(created.id)
            titleWantsFocus = true
        }
    }

    func editTitle(_ title: String) {
        guard var e = editor, !e.isTrashed, !e.title.utf8.elementsEqual(title.utf8) else { return }
        e.title = title
        editor = e
        markDirty(e)
    }

    func editBody(_ body: String) {
        guard var e = editor, !e.isTrashed, !e.body.utf8.elementsEqual(body.utf8) else { return }
        e.body = body
        editor = e
        markDirty(e)
    }

    private func markDirty(_ e: EditorState) {
        pending = PendingEdit(id: e.id, title: e.title, body: e.body)
        editVersion += 1
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Saves a pending edit now, after any save already running. Called before anything that changes
    /// what the editor shows, and before quit.
    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await save()
    }

    private func save() async {
        if let running = runningSave { await running.value }   // ⌘Q must not return mid-write
        guard let p = pending else { return }
        pending = nil
        let write = Task { [library] in
            _ = try? await library.updateNote(p.id, title: p.title, body: p.body)
        }
        runningSave = write
        await write.value
        if runningSave == write { runningSave = nil }
        await attempt {
            counts = try await library.counts()
            notes = try await library.notes(in: selection.scope)
        }
        if let saved = try? await library.note(p.id), var current = editor, current.id == p.id {
            current.modified = saved.modified
            editor = current
        }
    }

    func togglePin(_ id: ULID) async {
        await change(id) { note in try await self.library.setPinned(id, !note.pinned) }
    }

    func move(_ id: ULID, to notebookID: ULID?) async {
        await change(id) { _ in try await self.library.moveNote(id, to: notebookID) }
    }

    func setTags(_ id: ULID, _ tagIDs: Set<ULID>) async {
        await change(id) { _ in try await self.library.setTags(id, tagIDs) }
    }

    /// Adds or removes one tag on any note.
    func toggleTag(_ tagID: ULID, on noteID: ULID) async {
        await change(noteID) { note in
            let tags = note.tagIDs.contains(tagID) ? note.tagIDs.subtracting([tagID]) : note.tagIDs.union([tagID])
            try await self.library.setTags(noteID, tags)
        }
    }

    func trash(_ id: ULID) async {
        await change(id) { _ in try await self.library.trashNote(id) }
    }

    func restore(_ id: ULID) async {
        await change(id) { _ in try await self.library.restoreNote(id) }
    }

    func deletePermanently(_ id: ULID) async {
        await change(id) { _ in try await self.library.deleteNotePermanently(id) }
    }

    func emptyTrash() async {
        await flush()
        await attempt { _ = try await library.emptyTrash() }
        await refresh()
    }

    /// Saves pending edits, applies a library change to one note, then refreshes everything.
    private func change(_ id: ULID, _ body: (Note) async throws -> Void) async {
        await flush()
        await attempt {
            guard let note = try await library.note(id) else { return }
            try await body(note)
        }
        await refresh()
    }

    // MARK: Notebooks and tags

    func createNotebook(name: String, parent: ULID?) async -> Notebook? {
        var created: Notebook?
        await attempt { created = try await library.createNotebook(name: name, parentID: parent) }
        await refresh()
        return created
    }

    func renameNotebook(_ id: ULID, to name: String) async {
        await attempt { try await library.renameNotebook(id, to: name) }
        await refresh()
    }

    func moveNotebook(_ id: ULID, to parent: ULID?) async {
        await attempt { try await library.moveNotebook(id, toParent: parent) }
        await refresh()
    }

    func deleteNotebook(_ id: ULID) async {
        await flush()
        await attempt { try await library.deleteNotebook(id) }
        await refresh()
    }

    func createTag(name: String) async -> Tag? {
        var created: Tag?
        await attempt(tagName: name) { created = try await library.createTag(name: name) }
        await refresh()
        return created
    }

    func renameTag(_ id: ULID, to name: String) async {
        await attempt(tagName: name) { try await library.renameTag(id, to: name) }
        await refresh()
    }

    func deleteTag(_ id: ULID) async {
        await flush()
        await attempt { try await library.deleteTag(id) }
        await refresh()
    }

    // MARK: Search

    func setSearch(_ text: String) async {
        searchText = text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let before = visibleIDs
            clearSearchState()
            await fixSelection(previous: before)
            return
        }
        if searchHits == nil {
            if case .notebook(let id) = selection { searchNotebookID = id }
            if case .tag(let id) = selection { searchTagIDs = [id] }
        }
        await runSearch()
    }

    /// For the search field binding: shows the text at once and searches in the background.
    func typeSearch(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        Task { await setSearch(text) }
    }

    func setSearchNotebook(_ id: ULID?) async {
        searchNotebookID = id
        await runSearch()
    }

    func toggleSearchTag(_ id: ULID) async {
        if searchTagIDs.contains(id) { searchTagIDs.remove(id) } else { searchTagIDs.insert(id) }
        await runSearch()
    }

    private func clearSearchState() {
        searchGeneration += 1   // a search still running must not apply its results after this
        searchText = ""
        searchHits = nil
        searchTagIDs = []
        searchNotebookID = nil
    }

    private func runSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchText
        let before = visibleIDs
        var hits: [SearchHit] = []
        let inTrash = selection == .trash
        await attempt { hits = try await library.search(query, notebookID: searchNotebookID, tagIDs: searchTagIDs, inTrash: inTrash) }
        if let delay = searchDelay?(query) { try? await Task.sleep(for: delay) }
        guard generation == searchGeneration else { return }   // a newer search started meanwhile
        searchHits = hits
        await fixSelection(previous: before)
    }

    // MARK: Import and export

    func importMarkdownFolder(_ url: URL) async -> ImportReport? {
        await flush()
        var report: ImportReport?
        await attempt { report = try await library.importMarkdownFolder(from: url) }
        await refresh()
        return report
    }

    func export(to url: URL, notebook: ULID?) async -> ExportReport? {
        await flush()
        var report: ExportReport?
        await attempt { report = try await library.exportMarkdown(to: url, notebookID: notebook) }
        return report
    }

    // MARK: Errors

    private func attempt(tagName: String? = nil, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch let error as LibraryError {
            lastError = Self.message(for: error, tagName: tagName)
        } catch {
            lastError = "Something went wrong: \(error.localizedDescription)"
        }
    }

    static func message(for error: LibraryError, tagName: String?) -> String {
        switch error {
        case .duplicateTagName(let key): "A tag named “\(tagName ?? key)” already exists."
        case .notebookCycle: "A notebook can't go inside its own sub-notebook."
        case .invalidName: "Names can't be empty."
        case .notFound: "That item no longer exists."
        case .newerSchema: "This library was made by a newer Feather Note. Update the app to open it."
        }
    }
}

/// Which designed empty state a pane shows instead of content.
enum EmptyState: Equatable {
    /// A brand-new library: no notes anywhere.
    case firstLaunch
    /// The selected view or notebook has no notes.
    case emptyView
    case emptyTrash
    case noSearchResults(query: String, limitedTo: String?)
    /// There are notes, but none is open.
    case noNoteSelected
}

import FeatherCore

/// What the sidebar has selected.
enum SidebarItem: Hashable, Sendable {
    case all, recent, pinned, trash
    case notebook(ULID)
    case tag(ULID)

    var scope: NoteScope {
        switch self {
        case .all: .all
        case .recent: .recent
        case .pinned: .pinned
        case .trash: .trash
        case .notebook(let id): .notebook(id)
        case .tag(let id): .tag(id)
        }
    }
}

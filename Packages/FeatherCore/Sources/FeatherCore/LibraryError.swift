public enum LibraryError: Error, Equatable, Sendable {
    /// The database was written by a newer Feather Note; it is not opened and not changed.
    case newerSchema(found: Int, supported: Int)
    case notFound(ULID)
    case duplicateTagName(String)
    case notebookCycle
    case invalidName
}

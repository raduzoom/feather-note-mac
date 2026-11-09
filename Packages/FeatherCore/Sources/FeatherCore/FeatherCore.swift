/// FeatherCore: the local Feather Note library.
///
/// Open one with `Library.open(at:)`. It keeps notes, notebooks, tags and attachments in SQLite (WAL, FTS5),
/// writes a change-log row in the same transaction as every change, and exports to and imports from
/// Markdown folders as `universal/specs/data-model.md` describes.
public enum FeatherCore {
    public static let moduleName = "FeatherCore"
}

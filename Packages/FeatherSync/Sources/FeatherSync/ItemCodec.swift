import FeatherCore
import FeatherCrypto
import Foundation

/// An item as the server stores it: encrypted metadata and, for notes and attachments, an encrypted blob.
public struct EncodedItem: Sendable, Equatable {
    public var id: ULID
    public var type: ItemType
    public var meta: Data
    public var blob: Data?
}

/// A decrypted item, with the metadata fields this client doesn't know and the metadata version.
public enum DecodedItem: Sendable {
    case note(Note, extraMeta: String?, metaVersion: Int)
    case notebook(Notebook, extraMeta: String?, metaVersion: Int)
    case tag(Tag, extraMeta: String?, metaVersion: Int)
    case attachment(Attachment, content: Data, extraMeta: String?, metaVersion: Int)
}

public enum CodecError: Error, Equatable, Sendable {
    /// Encrypted metadata over 64 KiB (data-model.md "Encrypted metadata").
    case metadataTooLarge
    case malformedMetadata
}

/// data-model.md metadata JSON (`v: 1`) to FeatherCrypto envelopes and back. Unknown fields round-trip as text.
public enum ItemCodec {
    static let maxMeta = 65_536
    static let noteKeys: Set<String> = ["v", "title", "notebook_id", "tag_ids", "pinned", "created", "modified", "trashed_at"]
    static let notebookKeys: Set<String> = ["v", "name", "parent_id", "created", "modified"]
    static let tagKeys: Set<String> = ["v", "name", "created", "modified"]
    static let attachmentKeys: Set<String> = ["v", "filename", "mime", "size", "sha256", "created"]

    // MARK: Encode

    public static func encode(note: Note, extraMeta: String?, masterKey: Data) throws -> EncodedItem {
        let fields: [String: Any] = [
            "v": 1, "title": note.title, "notebook_id": id(note.notebookID),
            "tag_ids": note.tagIDs.map(\.description).sorted(), "pinned": note.pinned,
            "created": note.created, "modified": note.modified, "trashed_at": note.trashedAt.map { $0 as Any } ?? NSNull(),
        ]
        let key = try ItemKey.derive(masterKey: masterKey, itemID: note.id)
        return EncodedItem(id: note.id, type: .note, meta: try seal(fields, extraMeta, id: note.id, key: key),
                           blob: try Envelope.seal(Data(note.body.utf8), part: .noteBody, itemID: note.id, itemKey: key))
    }

    public static func encode(notebook: Notebook, extraMeta: String?, masterKey: Data) throws -> EncodedItem {
        let fields: [String: Any] = ["v": 1, "name": notebook.name, "parent_id": id(notebook.parentID),
                                     "created": notebook.created, "modified": notebook.modified]
        let key = try ItemKey.derive(masterKey: masterKey, itemID: notebook.id)
        return EncodedItem(id: notebook.id, type: .notebook, meta: try seal(fields, extraMeta, id: notebook.id, key: key), blob: nil)
    }

    public static func encode(tag: Tag, extraMeta: String?, masterKey: Data) throws -> EncodedItem {
        let fields: [String: Any] = ["v": 1, "name": tag.name, "created": tag.created, "modified": tag.modified]
        let key = try ItemKey.derive(masterKey: masterKey, itemID: tag.id)
        return EncodedItem(id: tag.id, type: .tag, meta: try seal(fields, extraMeta, id: tag.id, key: key), blob: nil)
    }

    public static func encode(attachment: Attachment, content: Data, extraMeta: String?, masterKey: Data) throws -> EncodedItem {
        let fields: [String: Any] = ["v": 1, "filename": attachment.filename, "mime": attachment.mime, "size": attachment.size,
                                     "sha256": attachment.sha256, "created": attachment.created]
        let key = try ItemKey.derive(masterKey: masterKey, itemID: attachment.id)
        return EncodedItem(id: attachment.id, type: .attachment, meta: try seal(fields, extraMeta, id: attachment.id, key: key),
                           blob: try Envelope.seal(content, part: .attachment, itemID: attachment.id, itemKey: key))
    }

    private static func id(_ id: ULID?) -> Any { id.map { $0.description as Any } ?? NSNull() }

    private static func seal(_ fields: [String: Any], _ extraMeta: String?, id: ULID, key: Data) throws -> Data {
        var all: [String: Any] = [:]
        if let extraMeta, let data = extraMeta.data(using: .utf8),
           let extra = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            all = extra
        }
        for (k, v) in fields { all[k] = v }
        let json = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys, .withoutEscapingSlashes])
        let sealed = try Envelope.seal(json, part: .metadata, itemID: id, itemKey: key)
        guard sealed.count <= maxMeta else { throw CodecError.metadataTooLarge }
        return sealed
    }

    // MARK: Decode

    public static func decode(type: ItemType, id: ULID, meta: Data, blob: Data?, masterKey: Data) throws -> DecodedItem {
        let key = try ItemKey.derive(masterKey: masterKey, itemID: id)
        let plain = try Envelope.open(meta, part: .metadata, itemID: id, itemKey: key)
        guard let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any], let v = int(json["v"]) else {
            throw CodecError.malformedMetadata
        }
        let version = Int(v)
        switch type {
        case .note:
            // without a blob, the caller keeps the body it has (unchanged since its last download)
            let body = try blob.map { try Envelope.open($0, part: .noteBody, itemID: id, itemKey: key) } ?? Data()
            let tags = (json["tag_ids"] as? [String] ?? []).compactMap(ULID.init(string:))
            let note = Note(id: id, title: json["title"] as? String ?? "", body: String(decoding: body, as: UTF8.self),
                            notebookID: (json["notebook_id"] as? String).flatMap(ULID.init(string:)), tagIDs: Set(tags),
                            pinned: json["pinned"] as? Bool ?? false, created: int(json["created"]) ?? 0,
                            modified: int(json["modified"]) ?? 0, trashedAt: int(json["trashed_at"]))
            return .note(note, extraMeta: extra(json, noteKeys), metaVersion: version)
        case .notebook:
            let nb = Notebook(id: id, name: json["name"] as? String ?? "", parentID: (json["parent_id"] as? String).flatMap(ULID.init(string:)),
                              created: int(json["created"]) ?? 0, modified: int(json["modified"]) ?? 0)
            return .notebook(nb, extraMeta: extra(json, notebookKeys), metaVersion: version)
        case .tag:
            let tag = Tag(id: id, name: json["name"] as? String ?? "", created: int(json["created"]) ?? 0, modified: int(json["modified"]) ?? 0)
            return .tag(tag, extraMeta: extra(json, tagKeys), metaVersion: version)
        case .attachment:
            guard let blob else { throw CodecError.malformedMetadata }
            let content = try Envelope.open(blob, part: .attachment, itemID: id, itemKey: key)
            let a = Attachment(id: id, filename: json["filename"] as? String ?? "attachment", mime: json["mime"] as? String ?? "application/octet-stream",
                               size: int(json["size"]) ?? Int64(content.count), sha256: json["sha256"] as? String ?? "",
                               created: int(json["created"]) ?? 0)
            return .attachment(a, content: content, extraMeta: extra(json, attachmentKeys), metaVersion: version)
        }
    }

    private static func int(_ value: Any?) -> Int64? {
        // a JSON true/false is an NSNumber too; only real numbers count
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.int64Value
    }

    private static func extra(_ json: [String: Any], _ known: Set<String>) -> String? {
        let rest = json.filter { !known.contains($0.key) }
        guard !rest.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

import Foundation
import UniformTypeIdentifiers

extension Library {
    var attachmentStore: AttachmentStore { AttachmentStore(root: directory.appending(path: "attachments")) }

    static func attachment(_ s: Statement) -> Attachment {
        Attachment(id: s.ulid(0), filename: s.text(1), mime: s.text(2), size: s.int64(3), sha256: s.text(4), created: s.int64(5))
    }

    static func mime(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty else { return "application/octet-stream" }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    public func addAttachment(data: Data, filename: String, mime: String? = nil) throws -> Attachment {
        let stored = try attachmentStore.put(data)
        return try write { db in
            let now = clock.now()
            let a = Attachment(id: ULID.generate(at: now), filename: filename, mime: mime ?? Self.mime(forFilename: filename),
                               size: Int64(data.count), sha256: stored.sha256, created: now)
            try db.run("INSERT INTO attachments (id, filename, mime, size, sha256, created) VALUES (?, ?, ?, ?, ?, ?)",
                       [.id(a.id), .text(a.filename), .text(a.mime), .int(a.size), .text(a.sha256), .int(now)])
            try log(.attachment, a.id, .upsert, bodyChanged: true, in: db)
            return a
        }
    }

    public func addAttachment(contentsOf fileURL: URL, mime: String? = nil) throws -> Attachment {
        try addAttachment(data: Data(contentsOf: fileURL), filename: fileURL.lastPathComponent, mime: mime)
    }

    public func attachment(_ id: ULID) throws -> Attachment? {
        try db.all("SELECT id, filename, mime, size, sha256, created FROM attachments WHERE id = ?", [.id(id)], Self.attachment).first
    }

    public func attachmentFileURL(_ id: ULID) throws -> URL? {
        try attachment(id).map { attachmentStore.url(for: $0.sha256) }
    }

    public func attachments() throws -> [Attachment] {
        try db.all("SELECT id, filename, mime, size, sha256, created FROM attachments ORDER BY id", [], Self.attachment)
    }
}

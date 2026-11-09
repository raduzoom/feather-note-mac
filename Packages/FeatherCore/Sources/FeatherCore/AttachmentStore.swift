import CryptoKit
import Foundation

/// Attachment content on disk, one file per distinct content: `root/<first 2 hex>/<sha256>`.
struct AttachmentStore {
    let root: URL

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func url(for sha256: String) -> URL {
        root.appending(path: String(sha256.prefix(2)), directoryHint: .isDirectory).appending(path: sha256)
    }

    /// Stores `data` unless the same content is already there. Writes through a temp file and a rename.
    func put(_ data: Data) throws -> (sha256: String, url: URL) {
        let hash = Self.sha256(data)
        let target = url(for: hash)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return (hash, target) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = target.deletingLastPathComponent().appending(path: ".\(hash).\(UUID().uuidString).tmp")
        try data.write(to: temp)
        do {
            try fm.moveItem(at: temp, to: target)
        } catch {
            try? fm.removeItem(at: temp)
            if !fm.fileExists(atPath: target.path) { throw error }   // someone else stored it first: fine
        }
        return (hash, target)
    }
}

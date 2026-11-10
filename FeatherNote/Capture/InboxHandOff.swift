import AppKit
import FeatherCore

/// How the sandboxed Share extension hands a capture to the app (plan Task 4, Decision 4).
///
/// An ad-hoc-signed sandboxed extension can't share an App Group container without a system prompt, so each
/// capture (the item plus its files, inlined) goes on its own named pasteboard, `app.feathernote.inbox.<id>`,
/// and the extension opens `feathernote://inbox?id=<id>`. The app moves that one capture into its inbox and
/// releases the pasteboard. One pasteboard per capture means two captures can never overwrite each other.
/// Switch to the App Group container once the app is Developer ID signed (Phase 10).
/// Compiled into both the app and the extension.
enum InboxHandOff {
    static let defaultPrefix = "app.feathernote.inbox"
    static let itemType = NSPasteboard.PasteboardType("app.feathernote.inbox-item")
    /// Files are inlined, so one capture is capped.
    static let maxBytes = 50 * 1024 * 1024

    enum HandOffError: Error, Equatable { case tooLarge }

    private struct Payload: Codable {
        struct File: Codable { var name: String; var data: Data }
        var item: InboxItem
        var files: [File]
    }

    static func pasteboard(for id: ULID, prefix: String) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("\(prefix).\(id)"))
    }

    /// The URL that wakes the app to collect capture `id`.
    static func wakeURL(for id: ULID) -> URL { URL(string: "feathernote://inbox?id=\(id)")! }

    /// The capture id in a wake URL, if it is one.
    static func captureID(in url: URL) -> ULID? {
        guard url.scheme == "feathernote", url.host() == "inbox",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value
        else { return nil }
        return ULID(string: value)
    }

    /// Puts a capture on its own pasteboard; returns the URL to open so the app collects it.
    @discardableResult
    static func deliver(_ item: InboxItem, files: [URL], prefix: String = defaultPrefix) throws -> URL {
        var total = 0
        var inlined: [Payload.File] = []
        for url in files {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard total <= maxBytes else { throw HandOffError.tooLarge }
            inlined.append(.init(name: url.lastPathComponent, data: try Data(contentsOf: url)))
        }
        let pb = pasteboard(for: item.id, prefix: prefix)
        pb.clearContents()
        pb.setData(try JSONEncoder().encode(Payload(item: item, files: inlined)), forType: itemType)
        return wakeURL(for: item.id)
    }

    /// Moves capture `id` into `inbox` and releases its pasteboard; false when there was nothing to collect.
    @discardableResult
    static func collect(id: ULID, into inbox: Inbox, prefix: String = defaultPrefix) throws -> Bool {
        let pb = pasteboard(for: id, prefix: prefix)
        guard let data = pb.data(forType: itemType), let p = try? JSONDecoder().decode(Payload.self, from: data) else { return false }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "FeatherHandOff-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let urls = try p.files.enumerated().map { n, f -> URL in
            let url = scratch.appending(path: "\(n)/\(f.name)")   // same-named files stay separate
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.data.write(to: url)
            return url
        }
        try inbox.write(p.item, files: urls)
        pb.clearContents()
        pb.releaseGlobally()
        return true
    }
}

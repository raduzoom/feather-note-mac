import AppKit
import FeatherCore

/// The Services menu entry "Save to FeatherMark": selected text, or a URL, becomes a note in the quick-note notebook.
/// The capture goes through the inbox, so it is never lost if saving fails.
@MainActor
final class ServicesProvider: NSObject {
    let model: AppModel

    init(model: AppModel) { self.model = model }

    /// NSServices entry point (NSMessage "saveToFeatherNote").
    @objc func saveToFeatherNote(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let item = Self.item(from: pboard) else {
            error?.pointee = "There was no text to save." as NSString
            return
        }
        do {
            try model.inbox.write(item, files: [])
        } catch let e {
            error?.pointee = e.localizedDescription as NSString
            return
        }
        Task { await model.drainInbox() }
    }

    /// Saves what's on `pboard`; false when there was nothing to save.
    func save(from pboard: NSPasteboard) async -> Bool {
        guard let item = Self.item(from: pboard) else { return false }
        do { try model.inbox.write(item, files: []) } catch { return false }
        _ = await model.drainInbox()
        return true
    }

    /// `.url` when the text is a single URL (or only a URL is offered), `.text` otherwise.
    static func item(from pboard: NSPasteboard) -> InboxItem? {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = (pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first(where: { !$0.isFileURL })
        if let single = URL(string: text), !text.contains(where: \.isWhitespace), let scheme = single.scheme,
           ["http", "https"].contains(scheme.lowercased()), single.host() != nil {
            return InboxItem(id: ULID.generate(at: now), kind: .url, url: text, created: now)
        }
        if text.isEmpty, let url {
            return InboxItem(id: ULID.generate(at: now), kind: .url, url: url.absoluteString, created: now)
        }
        guard !text.isEmpty else { return nil }
        return InboxItem(id: ULID.generate(at: now), kind: .text, text: text, created: now)
    }
}

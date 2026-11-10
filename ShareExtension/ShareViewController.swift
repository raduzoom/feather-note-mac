import AppKit
import FeatherCore
import UniformTypeIdentifiers

/// Share › FeatherMark: saves the shared text, URL (with its title) or files as a note.
/// The capture goes to the app through `InboxHandOff`; the app files it into the quick-note notebook.
final class ShareViewController: NSViewController {
    private let status = NSTextField(labelWithString: "")

    override func loadView() {
        let title = NSTextField(labelWithString: "Save to FeatherMark")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let save = NSButton(title: "Save", target: self, action: #selector(saveItem))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelItem))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])
        let stack = NSStackView(views: [title, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
        view = stack
        status.stringValue = summary()
    }

    private var items: [NSExtensionItem] { (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] }

    private func summary() -> String {
        let title = items.first?.attributedContentText?.string ?? items.first?.attributedTitle?.string ?? ""
        return title.isEmpty ? "Saves to your quick-note notebook." : title
    }

    @objc private func cancelItem() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    @objc private func saveItem() {
        Task { @MainActor in
            do {
                let (item, files) = await Self.capture(from: items)
                let wake = try InboxHandOff.deliver(item, files: files)
                NSWorkspace.shared.open(wake)
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                status.stringValue = error as? InboxHandOff.HandOffError == .tooLarge
                    ? "These files are too large to save from here. Drop them on a note instead."
                    : "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    /// `.url` for a web URL, `.files` for files, `.text` otherwise.
    static func capture(from items: [NSExtensionItem]) async -> (InboxItem, [URL]) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var text: String?
        var webURL: URL?
        var files: [URL] = []
        let title = items.first?.attributedTitle?.string
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await load(URL.self, provider, UTType.fileURL) {
                files.append(url)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await load(URL.self, provider, UTType.url) {
                if url.isFileURL { files.append(url) } else { webURL = url }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let s = await load(String.self, provider, UTType.plainText) {
                text = [text, s].compactMap { $0 }.joined(separator: "\n\n")
            }
        }
        if text == nil { text = items.first?.attributedContentText?.string }
        let id = ULID.generate(at: now)
        if let webURL {
            return (InboxItem(id: id, kind: .url, text: text, url: webURL.absoluteString, title: title, created: now), [])
        }
        if !files.isEmpty {
            return (InboxItem(id: id, kind: .files, text: text, title: title, created: now), files)
        }
        return (InboxItem(id: id, kind: .text, text: text ?? "", created: now), [])
    }

    private static func load<T: Sendable>(_ type: T.Type, _ provider: NSItemProvider, _ uti: UTType) async -> T? {
        await withCheckedContinuation { c in
            provider.loadItem(forTypeIdentifier: uti.identifier, options: nil) { value, _ in
                if let v = value as? T { c.resume(returning: v); return }
                if T.self == URL.self, let d = value as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) {
                    c.resume(returning: u as? T); return
                }
                if T.self == String.self, let d = value as? Data { c.resume(returning: String(data: d, encoding: .utf8) as? T); return }
                c.resume(returning: nil)
            }
        }
    }
}

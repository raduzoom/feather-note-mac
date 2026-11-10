import Foundation

extension Library {
    /// Turns a captured item into a note (id = the item's id) with its files as attachments, in one transaction.
    /// If that note already exists, returns it unchanged: capturing the same item twice makes one note.
    public func capture(_ item: InboxItem, files: [URL], into notebookID: ULID?) throws -> Note {
        if let existing = try note(item.id) { return existing }
        return try write { _ in
            var links: [String] = []
            for file in files {
                let a = try addAttachment(contentsOf: file)
                let name = Self.escapeLinkText(a.filename)
                let link = "[\(name)](feather://attachment/\(a.id))"
                links.append(a.mime.hasPrefix("image/") ? "!" + link : link)
            }
            var (title, body) = Self.titleAndBody(for: item)
            if !links.isEmpty {
                body = body.isEmpty ? links.joined(separator: "\n") : body + "\n\n" + links.joined(separator: "\n")
            }
            return try createNote(title: title, body: body, notebookID: notebookID, id: item.id, created: item.created)
        }
    }

    /// Captures every pending inbox item, removing each folder after its note commits.
    public func drain(_ inbox: Inbox, into notebookID: ULID?) throws -> [Note] {
        var notes: [Note] = []
        for (item, folder) in try inbox.pending() {
            let existed = try note(item.id) != nil
            let note = try capture(item, files: item.files.map { folder.appending(path: $0) }, into: notebookID)
            try inbox.remove(item.id)
            if !existed { notes.append(note) }
        }
        return notes
    }

    static func titleAndBody(for item: InboxItem) -> (String, String) {
        let text = item.text ?? ""
        switch item.kind {
        case .url:
            let url = item.url ?? ""
            let title = item.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? URL(string: url)?.host() ?? url
            var body = "<\(url)>"
            let quote = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quote.isEmpty {
                body += "\n\n" + quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            }
            // a page title is kept whole (only its first line), however long
            let firstLine = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? title
            return (firstLine.trimmingCharacters(in: .whitespaces), body)
        case .text:
            return CaptureText.split(text)
        case .files:
            if let title = item.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (title, text.trimmingCharacters(in: .whitespacesAndNewlines))   // keep all the text
            }
            return CaptureText.split(text)
        }
    }

    static func escapeLinkText(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}

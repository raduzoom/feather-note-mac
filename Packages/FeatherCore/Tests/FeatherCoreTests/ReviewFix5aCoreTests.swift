import Foundation
import Testing
@_spi(Testing) @testable import FeatherCore

/// Phase 5a review probes (capture). Each test states what a person would expect; RED means a finding.
@Suite struct ReviewProbe5aCore {
    func item(_ kind: InboxItem.Kind, text: String? = nil, title: String? = nil, at t: Int64 = TestLibrary.t0) -> InboxItem {
        InboxItem(id: ULID.generate(at: t), kind: kind, text: text, title: title, created: t)
    }

    /// A quick note / Services capture that is one long paragraph (no line break) keeps every word.
    @Test func probeLongFirstLineIsNotDropped() async throws {
        let words = (1...60).map { "word\($0)" }
        let paragraph = words.joined(separator: " ")   // ~ 400 characters, one line
        let lib = try TestLibrary.open()
        let note = try await lib.capture(item(.text, text: paragraph), files: [], into: nil)
        let saved = note.title + "\n" + note.body
        let missing = words.filter { !saved.contains($0) }
        #expect(missing.isEmpty, "lost \(missing.count) of 60 words, e.g. \(missing.prefix(3)); title=\(note.title.count) chars, body=\(note.body.debugDescription)")
    }

    /// A Share capture of files with a title and text keeps the text's first line.
    @Test func probeFilesCaptureKeepsFirstTextLine() async throws {
        let lib = try TestLibrary.open()
        let f = TestLibrary.directory().appending(path: "a.pdf")
        try Data([1, 2]).write(to: f)
        let note = try await lib.capture(item(.files, text: "First line of the comment\nSecond line", title: "Shared files"),
                                         files: [f], into: nil)
        #expect((note.title + note.body).contains("First line of the comment"), "title=\(note.title) body=\(note.body.debugDescription)")
    }

    /// Two shared files with the same name (from different folders) keep their own contents.
    @Test func probeSameNamedFilesKeepBothContents() async throws {
        let lib = try TestLibrary.open()
        let d1 = TestLibrary.directory(), d2 = TestLibrary.directory()
        let a = d1.appending(path: "image.png"), b = d2.appending(path: "image.png")
        try Data([1, 1, 1]).write(to: a)
        try Data([2, 2, 2, 2]).write(to: b)
        let inbox = Inbox(directory: TestLibrary.directory().appending(path: "Inbox"))
        try inbox.write(item(.files), files: [a, b])
        _ = try await lib.drain(inbox, into: nil)
        let atts = try await lib.attachments()
        #expect(Set(atts.map(\.sha256)).count == 2, "attachments: \(atts.map { "\($0.filename) \($0.size) bytes" })")
    }

    /// A shared file that happens to be called item.json is kept as it was.
    @Test func probeFileNamedItemJsonIsKept() async throws {
        let lib = try TestLibrary.open()
        let f = TestLibrary.directory().appending(path: "item.json")
        let original = Data(#"{"settings": true}"#.utf8)
        try original.write(to: f)
        let inbox = Inbox(directory: TestLibrary.directory().appending(path: "Inbox"))
        try inbox.write(item(.files), files: [f])
        _ = try await lib.drain(inbox, into: nil)
        let att = try #require(try await lib.attachments().first)
        let stored = try Data(contentsOf: try #require(try await lib.attachmentFileURL(att.id)))
        #expect(stored == original, "attachment holds \(String(decoding: stored.prefix(60), as: UTF8.self))")
    }

    /// One capture that can't be filed must not hold back the captures after it.
    @Test(.disabled("Deferred minor (5a review finding 7): one unreadable inbox item stops later items from being filed"))
    func probeBadItemDoesNotBlockLaterCaptures() async throws {
        let lib = try TestLibrary.open()
        let inbox = Inbox(directory: TestLibrary.directory().appending(path: "Inbox"))
        let f = TestLibrary.directory().appending(path: "gone.pdf")
        try Data([1]).write(to: f)
        let bad = item(.files, at: TestLibrary.t0)
        try inbox.write(bad, files: [f])
        // the file disappears from the item folder (disk error, cleanup tool, partial copy)
        try FileManager.default.removeItem(at: inbox.directory.appending(path: bad.id.description).appending(path: "gone.pdf"))
        try inbox.write(item(.text, text: "Later capture", at: TestLibrary.t0 + 1000), files: [])
        _ = try? await lib.drain(inbox, into: nil)
        _ = try? await lib.drain(inbox, into: nil)
        let titles = try await lib.notes(in: .all).map(\.title)
        let pendingCount = try inbox.pending().count
        #expect(titles.contains("Later capture"), "notes: \(titles); pending: \(pendingCount)")
    }
}

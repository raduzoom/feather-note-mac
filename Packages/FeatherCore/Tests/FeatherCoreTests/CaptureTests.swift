import Foundation
import Testing
@_spi(Testing) @testable import FeatherCore

@Suite struct CaptureTests {
    func item(_ kind: InboxItem.Kind, text: String? = nil, url: String? = nil, title: String? = nil, files: [String] = []) -> InboxItem {
        InboxItem(id: ULID.generate(at: TestLibrary.t0), kind: kind, text: text, url: url, title: title, files: files, created: TestLibrary.t0)
    }

    func file(_ name: String, _ bytes: [UInt8] = [1, 2, 3]) -> URL {
        let url = TestLibrary.directory().appending(path: name)
        try! Data(bytes).write(to: url)
        return url
    }

    @Test func splitTakesFirstLineAsTitle() {
        let (title, body) = CaptureText.split("  \nBuy flashing\nQuote by Friday")
        #expect(title == "Buy flashing")
        #expect(body == "Quote by Friday")
        let long = String(repeating: "word ", count: 30) + "end"   // 153 characters
        let cut = CaptureText.split(long).title
        #expect(cut.count <= 100 && !cut.hasSuffix(" ") && long.hasPrefix(cut))
        #expect(CaptureText.split("one line") == ("one line", ""))
    }

    @Test func urlCaptureBody() async throws {
        let lib = try TestLibrary.open()
        let note = try await lib.capture(item(.url, text: "line", url: "https://a.example/x"), files: [], into: nil)
        #expect(note.title == "a.example")
        #expect(note.body == "<https://a.example/x>\n\n> line")
    }

    @Test func filesBecomeAttachments() async throws {
        let lib = try TestLibrary.open()
        let png = file("shot.png"), pdf = file("bill.pdf", [4, 5])
        let note = try await lib.capture(item(.files, files: ["shot.png", "bill.pdf"]), files: [png, pdf], into: nil)
        let lines = note.body.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("![shot.png](feather://attachment/"))
        #expect(lines[1].hasPrefix("[bill.pdf](feather://attachment/"))
        #expect(try await lib.attachments().count == 2)
    }

    @Test func textCaptureUsesSplitAndNotebook() async throws {
        let lib = try TestLibrary.open()
        let nb = try await lib.createNotebook(name: "Inbox", parentID: nil)
        let note = try await lib.capture(item(.text, text: "Idea\nmore"), files: [], into: nb.id)
        #expect(note.title == "Idea" && note.body == "more" && note.notebookID == nb.id)
    }

    @Test func drainIsIdempotent() async throws {
        let lib = try TestLibrary.open()
        let inbox = Inbox(directory: TestLibrary.directory().appending(path: "Inbox"))
        try inbox.write(item(.text, text: "Once"), files: [])
        _ = try await lib.drain(inbox, into: nil)
        // a second drain (or a second app instance) must not create another note
        #expect(try await lib.drain(inbox, into: nil).isEmpty)
        #expect(try inbox.pending().isEmpty)
        #expect(try await lib.notes(in: .all).count == 1)
    }

    @Test func sameItemTwiceCreatesOneNote() async throws {
        let lib = try TestLibrary.open()
        let i = item(.text, text: "Twice")
        let first = try await lib.capture(i, files: [], into: nil)
        let second = try await lib.capture(i, files: [], into: nil)
        #expect(first.id == second.id)
        #expect(try await lib.notes(in: .all).count == 1)
    }

    @Test func itemSurvivesUntilNoteCommitted() async throws {
        let lib = try TestLibrary.open()
        let inbox = Inbox(directory: TestLibrary.directory().appending(path: "Inbox"))
        try inbox.write(item(.text, text: "Keep me"), files: [])
        struct Boom: Error {}
        await lib.setBeforeCommitHook { throw Boom() }
        await #expect(throws: Boom.self) { try await lib.drain(inbox, into: nil) }
        await lib.setBeforeCommitHook(nil)
        #expect(try inbox.pending().count == 1)
        #expect(try await lib.notes(in: .all).isEmpty)
    }

    @Test func unreadableItemIsSkippedNotDeleted() throws {
        let dir = TestLibrary.directory().appending(path: "Inbox")
        let inbox = Inbox(directory: dir)
        let bad = dir.appending(path: "01JC8ZQ6V4N1XG2H3K5M7P9R0T")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: bad.appending(path: "item.json"))
        #expect(try inbox.pending().isEmpty)
        #expect(FileManager.default.fileExists(atPath: bad.path))
    }
}

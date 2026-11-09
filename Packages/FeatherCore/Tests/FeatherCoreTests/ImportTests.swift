import Foundation
import Testing
@_spi(Testing) @testable import FeatherCore

private func write(_ text: String, _ path: String, in root: URL) throws {
    try write(Data(text.utf8), path, in: root)
}

private func write(_ data: Data, _ path: String, in root: URL) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

@Test func importsFoldersNotesAndFrontMatter() async throws {
    let src = TestLibrary.directory()
    try write("---\ntitle: Real title\ntags: [Travel, new]\npinned: true\ncreated: 2025-11-09T13:52:00.123Z\nmodified: 2025-11-09T14:52:35.001Z\n---\n\nHello\n", "Home/Trip.md", in: src)
    try write("No front matter", "Home/Recipes/Pasta.MD", in: src)
    try write("root", "Inbox.md", in: src)
    try FileManager.default.createDirectory(at: src.appending(path: "Empty"), withIntermediateDirectories: true)
    let lib = try TestLibrary.open()
    let existing = try await lib.createTag(name: "travel")
    let report = try await lib.importMarkdownFolder(from: src)
    #expect(report == ImportReport(notes: 3, notebooks: 3, attachments: 0, skipped: []))
    let notebooks = try await lib.notebooks()
    #expect(Set(notebooks.map(\.name)) == ["Home", "Recipes", "Empty"])
    let home = try #require(notebooks.first { $0.name == "Home" })
    #expect(notebooks.first { $0.name == "Recipes" }?.parentID == home.id)
    let trip = try #require(try await lib.notes(in: .all).first { $0.title == "Real title" })
    let note = try #require(try await lib.note(trip.id))
    #expect(note.body == "Hello\n" && note.pinned && note.notebookID == home.id)
    #expect(note.created == 1_762_696_320_123 && note.modified == 1_762_699_955_001)
    #expect(note.tagIDs.contains(existing.id) && note.tagIDs.count == 2)
    #expect(try await lib.tags().count == 2)
    let pasta = try #require(try await lib.notes(in: .all).first { $0.title == "Pasta" })
    #expect(try await lib.note(pasta.id)?.body == "No front matter")
    #expect(try await lib.notes(in: .all).first { $0.title == "Inbox" }?.notebookID == nil)
}

@Test func importIntoNotebook() async throws {
    let src = TestLibrary.directory()
    try write("x", "a.md", in: src)
    let lib = try TestLibrary.open()
    let parent = try await lib.createNotebook(name: "Imported", parentID: nil)
    _ = try await lib.importMarkdownFolder(from: src, into: parent.id)
    #expect(try await lib.notes(in: .all).first?.notebookID == parent.id)
}

@Test func unknownFrontMatterStaysInBody() async throws {
    let src = TestLibrary.directory()
    let text = "---\naliases: [x]\ntitle: T\n---\nBody"
    try write(text, "n.md", in: src)
    let lib = try TestLibrary.open()
    _ = try await lib.importMarkdownFolder(from: src)
    let id = try #require(try await lib.notes(in: .all).first?.id)
    let note = try #require(try await lib.note(id))
    #expect(note.title == "T" && note.body == text)
}

@Test func linksBecomeAttachments() async throws {
    let src = TestLibrary.directory()
    try write(Data([1, 2, 3]), "Home/_attachments/My Note/a b.png", in: src)
    try write(Data([4]), "Home/doc.pdf", in: src)
    try write("![](_attachments/My%20Note/a%20b.png)\n[d](doc.pdf) [again](./doc.pdf)\n", "Home/My Note.md", in: src)
    try write("[shared](Home/doc.pdf)", "other.md", in: src)
    let lib = try TestLibrary.open()
    let report = try await lib.importMarkdownFolder(from: src)
    #expect(report.attachments == 2 && report.skipped.isEmpty && report.notebooks == 1)
    let attachments = try await lib.attachments()
    let png = try #require(attachments.first { $0.filename == "a b.png" })
    let pdf = try #require(attachments.first { $0.filename == "doc.pdf" })
    let id = try #require(try await lib.notes(in: .all).first { $0.title == "My Note" }?.id)
    #expect(try await lib.note(id)?.body == "![](feather://attachment/\(png.id))\n[d](feather://attachment/\(pdf.id)) [again](feather://attachment/\(pdf.id))\n")
    let other = try #require(try await lib.notes(in: .all).first { $0.title == "other" }?.id)
    #expect(try await lib.note(other)?.body == "[shared](feather://attachment/\(pdf.id))")
}

@Test func linksInCodeAreNotRewritten() async throws {
    let src = TestLibrary.directory()
    try write(Data([1]), "img.png", in: src)
    let body = "`[a](img.png)`\n```\n[b](img.png)\n```\n[c](img.png)\n"
    try write(body, "n.md", in: src)
    let lib = try TestLibrary.open()
    _ = try await lib.importMarkdownFolder(from: src)
    let a = try #require(try await lib.attachments().first)
    let id = try #require(try await lib.notes(in: .all).first?.id)
    #expect(try await lib.note(id)?.body == "`[a](img.png)`\n```\n[b](img.png)\n```\n[c](feather://attachment/\(a.id))\n")
}

@Test func linksToMarkdownFilesStay() async throws {
    let src = TestLibrary.directory()
    try write("[other](other.md) [web](https://x.y/a.png) [anchor](#top) [abs](/etc/hosts) [missing](nope.png) [out](../outside.png)", "n.md", in: src)
    try write("other", "other.md", in: src)
    try write(Data([1]), "../outside.png", in: src)
    let lib = try TestLibrary.open()
    let report = try await lib.importMarkdownFolder(from: src)
    #expect(report.attachments == 0)
    let id = try #require(try await lib.notes(in: .all).first { $0.title == "n" }?.id)
    #expect(try await lib.note(id)?.body == "[other](other.md) [web](https://x.y/a.png) [anchor](#top) [abs](/etc/hosts) [missing](nope.png) [out](../outside.png)")
}

@Test func nonUTF8FileIsSkippedAndReported() async throws {
    let src = TestLibrary.directory()
    try write(Data([0x63, 0x61, 0x66, 0xE9]), "bad.md", in: src)
    try write(Data([0xEF, 0xBB, 0xBF] + Array("bom".utf8)), "bom.md", in: src)
    let lib = try TestLibrary.open()
    let report = try await lib.importMarkdownFolder(from: src)
    #expect(report.skipped == [ImportReport.Skipped(path: "bad.md", reason: .notUTF8)])
    #expect(report.notes == 1)
    let id = try #require(try await lib.notes(in: .all).first?.id)
    #expect(try await lib.note(id)?.body == "bom")
}

@Test func hiddenEntriesAreIgnored() async throws {
    let src = TestLibrary.directory()
    try write("x", ".obsidian/x.md", in: src)
    try write(Data([1]), ".DS_Store", in: src)
    try write("y", "Notes/.hidden.md", in: src)
    let lib = try TestLibrary.open()
    let report = try await lib.importMarkdownFolder(from: src)
    #expect(report == ImportReport(notes: 0, notebooks: 1, attachments: 0, skipped: []))
}

@Test func unreferencedFilesAreReported() async throws {
    let src = TestLibrary.directory()
    try write(Data([1]), "Home/photo.jpg", in: src)
    try write("note", "Home/n.md", in: src)
    let lib = try TestLibrary.open()
    let report = try await lib.importMarkdownFolder(from: src)
    #expect(report.skipped == [ImportReport.Skipped(path: "Home/photo.jpg", reason: .unreferencedFile)])
}

@Test func featherIDReusedOnlyIfFree() async throws {
    let lib = try TestLibrary.open()
    let taken = try await lib.createNote(title: "existing")
    let free = ULID.generate(at: 42)
    let src = TestLibrary.directory()
    try write("---\nfeather_id: \(taken.id)\n---\n\na", "a.md", in: src)
    try write("---\nfeather_id: \(free)\n---\n\nb", "b.md", in: src)
    try write("---\nfeather_id: \(free)\n---\n\nc", "c.md", in: src)
    try write("---\nfeather_id: not-a-ulid\n---\n\nd", "d.md", in: src)
    _ = try await lib.importMarkdownFolder(from: src)
    let all = try await lib.notes(in: .all)
    #expect(all.count == 5)
    #expect(Set(all.map(\.id)).count == 5)
    #expect(all.first { $0.title == "b" }?.id == free)
    #expect(all.first { $0.title == "a" }?.id != taken.id)
    #expect(all.first { $0.title == "c" }?.id != free)
}

@Test func failedImportImportsNothing() async throws {
    let src = TestLibrary.directory()
    try write("x", "Home/a.md", in: src)
    let lib = try TestLibrary.open()
    await lib.setBeforeCommitHook { throw Boom() }
    await #expect(throws: Boom.self) { try await lib.importMarkdownFolder(from: src) }
    await lib.setBeforeCommitHook(nil)
    #expect(try await lib.notes(in: .all).isEmpty)
    #expect(try await lib.notebooks().isEmpty)
    #expect(try await lib.changes(after: 0).isEmpty)
}

@Test func roundTripKeepsEverything() async throws {
    let (lib, groceries) = try await specExampleLibrary()
    let tricky = "---\r\ntitle: x\r\n---\r\nCafe\u{301}\u{00A0} 😀  \n"
    let t1 = try await lib.createTag(name: "shopping")
    let t2 = try await lib.createTag(name: "a, b")
    try await lib.setTags(groceries.id, [t1.id, t2.id])
    try await lib.setPinned(groceries.id, true)
    _ = try await lib.createNote(title: "yes", body: tricky)
    _ = try await lib.createNote(title: "Ideas: big", body: "")
    let t3 = try await lib.createTag(name: "Mom's")
    let t4 = try await lib.createTag(name: "don't")
    let img = try await lib.addAttachment(data: Data([5, 6]), filename: "crlf.png")
    _ = try await lib.createNote(title: "Windows", body: "line one\r\n\r\n![x](feather://attachment/\(img.id))\r\n", tagIDs: [t3.id, t4.id])

    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    let copy = try TestLibrary.open()
    let imported = try await copy.importMarkdownFolder(from: report.root)
    #expect(imported.skipped.isEmpty && imported.notes == 7 && imported.attachments == 3)

    func tree(_ l: Library) async throws -> Set<String> {
        let nbs = try await l.notebooks()
        let byID = Dictionary(uniqueKeysWithValues: nbs.map { ($0.id, $0) })
        func path(_ id: ULID?) -> String {
            guard let id, let nb = byID[id] else { return "" }
            return path(nb.parentID) + "/" + nb.name
        }
        return Set(nbs.map { path($0.id) })
    }
    #expect(try await tree(lib) == tree(copy))

    let oldAttachments = try await lib.attachments()
    let newAttachments = try await copy.attachments()
    var idMap: [String: String] = [:]
    for a in oldAttachments {
        let b = try #require(newAttachments.first { $0.filename == a.filename && $0.sha256 == a.sha256 })
        idMap[a.id.description] = b.id.description
        let oldData = try Data(contentsOf: try #require(try await lib.attachmentFileURL(a.id)))
        let newData = try Data(contentsOf: try #require(try await copy.attachmentFileURL(b.id)))
        #expect(oldData == newData)
    }
    let oldTags = Dictionary(uniqueKeysWithValues: try await lib.tags().map { ($0.id, $0.name) })
    let newTags = Dictionary(uniqueKeysWithValues: try await copy.tags().map { ($0.id, $0.name) })
    for summary in try await lib.notes(in: .all) {
        let a = try #require(try await lib.note(summary.id))
        let b = try #require(try await copy.note(summary.id), "note \(a.title) kept its id")
        var expected = a.body
        for (old, new) in idMap { expected = expected.replacingOccurrences(of: old, with: new) }
        #expect(Array(b.body.utf8) == Array(expected.utf8), "body of \(a.title)")
        #expect(b.title == a.title && b.pinned == a.pinned && b.created == a.created && b.modified == a.modified)
        #expect(Set(b.tagIDs.compactMap { newTags[$0] }) == Set(a.tagIDs.compactMap { oldTags[$0] }))
    }
}

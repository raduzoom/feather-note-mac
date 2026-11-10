import Foundation
import Testing
@testable import FeatherCore

func relativePaths(_ root: URL) throws -> Set<String> {
    Set(try FileManager.default.subpathsOfDirectory(atPath: root.path))
}

/// The library from data-model.md "Example".
func specExampleLibrary() async throws -> (Library, Note) {
    let lib = try TestLibrary.open()
    let home = try await lib.createNotebook(name: "Home", parentID: nil)
    let recipes = try await lib.createNotebook(name: "Recipes", parentID: home.id)
    _ = try await lib.createNotebook(name: "Work", parentID: nil)
    _ = try await lib.createNote(title: "Inbox", body: "inbox")
    _ = try await lib.createNote(title: "Pasta", body: "one", notebookID: recipes.id)
    _ = try await lib.createNote(title: "Pasta", body: "two", notebookID: recipes.id)
    let jpg = try await lib.addAttachment(data: Data("jpeg".utf8), filename: "receipt.jpg")
    let pdf = try await lib.addAttachment(data: Data("pdf".utf8), filename: "list.pdf")
    let groceries = try await lib.createNote(title: "Groceries",
        body: "- [ ] Milk\n![](feather://attachment/\(jpg.id))\n[list](feather://attachment/\(pdf.id))\n",
        notebookID: home.id)
    return (lib, groceries)
}

@Test func exportMatchesSpecExample() async throws {
    let (lib, _) = try await specExampleLibrary()
    let dest = TestLibrary.directory()
    let report = try await lib.exportMarkdown(to: dest)
    #expect(report.root.lastPathComponent == "FeatherMark Export")
    #expect(report.notes == 4 && report.notebooks == 3 && report.attachments == 2)
    #expect(try relativePaths(report.root) == [
        "Inbox.md", "Home", "Home/Groceries.md", "Home/_attachments", "Home/_attachments/Groceries",
        "Home/_attachments/Groceries/receipt.jpg", "Home/_attachments/Groceries/list.pdf",
        "Home/Recipes", "Home/Recipes/Pasta.md", "Home/Recipes/Pasta (2).md", "Work",
    ])
    let text = try String(contentsOf: report.root.appending(path: "Home/Groceries.md"), encoding: .utf8)
    #expect(text.contains("](_attachments/Groceries/receipt.jpg)"))
    #expect(text.contains("[list](_attachments/Groceries/list.pdf)"))
    #expect(text.hasPrefix("---\nfeather_id: "))
    #expect(text.hasSuffix("\n---\n\n- [ ] Milk\n![](_attachments/Groceries/receipt.jpg)\n[list](_attachments/Groceries/list.pdf)\n"))
    #expect(try Data(contentsOf: report.root.appending(path: "Home/_attachments/Groceries/receipt.jpg")) == Data("jpeg".utf8))
}

@Test func attachmentPathsArePercentEncoded() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.addAttachment(data: Data([1]), filename: "floor plan.png")
    _ = try await lib.createNote(title: "My Note", body: "![](feather://attachment/\(a.id)) [x](feather://attachment/\(ULID.generate(at: 5)))")
    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    let text = try String(contentsOf: report.root.appending(path: "My Note.md"), encoding: .utf8)
    #expect(text.contains("![](_attachments/My%20Note/floor%20plan.png)"))
    #expect(text.contains("[x](feather://attachment/"))   // unknown id stays as written
}

@Test func sameNameAttachmentsInOneNoteGetNumbered() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.addAttachment(data: Data([1]), filename: "scan.pdf")
    let b = try await lib.addAttachment(data: Data([2]), filename: "Scan.pdf")
    _ = try await lib.createNote(title: "n", body: "[a](feather://attachment/\(a.id)) [b](feather://attachment/\(b.id)) [a](feather://attachment/\(a.id))")
    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    #expect(try relativePaths(report.root.appending(path: "_attachments/n")) == ["scan.pdf", "Scan (2).pdf"])
    #expect(report.attachments == 2)
}

@Test func collisionsBetweenNotesAndNotebooks() async throws {
    let lib = try TestLibrary.open()
    _ = try await lib.createNote(title: "Pasta")
    _ = try await lib.createNote(title: "pasta")
    _ = try await lib.createNote(title: "")
    _ = try await lib.createNote(title: "a/b")
    _ = try await lib.createNote(title: "CON")
    _ = try await lib.createNotebook(name: "Dup", parentID: nil)
    _ = try await lib.createNotebook(name: "dup", parentID: nil)
    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    #expect(try relativePaths(report.root) == ["Pasta.md", "pasta (2).md", "Untitled.md", "a-b.md", "CON-.md", "Dup", "dup (2)"])
}

@Test func notebookNamedAttachmentsIsRenamed() async throws {
    let lib = try TestLibrary.open()
    _ = try await lib.createNotebook(name: "_Attachments", parentID: nil)
    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    #expect(try relativePaths(report.root) == ["_Attachments (2)"])
}

@Test func trashedNotesAreNotExported() async throws {
    let lib = try TestLibrary.open()
    let n = try await lib.createNote(title: "gone")
    try await lib.trashNote(n.id)
    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    #expect(try relativePaths(report.root).isEmpty && report.notes == 0)
}

@Test func exportNeverOverwrites() async throws {
    let lib = try TestLibrary.open()
    let dest = TestLibrary.directory()
    let first = try await lib.exportMarkdown(to: dest)
    let second = try await lib.exportMarkdown(to: dest)
    #expect(first.root.lastPathComponent == "FeatherMark Export")
    #expect(second.root.lastPathComponent == "FeatherMark Export (2)")
}

@Test func exportOneNotebook() async throws {
    let lib = try TestLibrary.open()
    let home = try await lib.createNotebook(name: "Home", parentID: nil)
    let sub = try await lib.createNotebook(name: "Sub", parentID: home.id)
    _ = try await lib.createNote(title: "a", notebookID: home.id)
    _ = try await lib.createNote(title: "b", notebookID: sub.id)
    _ = try await lib.createNote(title: "outside")
    let report = try await lib.exportMarkdown(to: TestLibrary.directory(), notebookID: home.id)
    #expect(report.root.lastPathComponent == "Home")
    #expect(try relativePaths(report.root) == ["a.md", "Sub", "Sub/b.md"])
}

@Test func tagsAndPinnedInFrontMatter() async throws {
    let lib = try TestLibrary.open()
    let t1 = try await lib.createTag(name: "shopping")
    let t2 = try await lib.createTag(name: "home")
    let n = try await lib.createNote(title: "x", tagIDs: [t1.id, t2.id])
    try await lib.setPinned(n.id, true)
    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    let text = try String(contentsOf: report.root.appending(path: "x.md"), encoding: .utf8)
    #expect(text.contains("\ntags: [home, shopping]\npinned: true\n"))
}

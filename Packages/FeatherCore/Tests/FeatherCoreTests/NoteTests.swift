import Foundation
import Testing
@_spi(Testing) @testable import FeatherCore

private let day: Int64 = 86_400_000
struct Boom: Error {}

@Test func createAndReadNote() async throws {
    let lib = try TestLibrary.open()
    let nb = try await lib.createNotebook(name: "Home", parentID: nil)
    let tag = try await lib.createTag(name: "shopping")
    let n = try await lib.createNote(title: "Groceries", body: "- [ ] Milk", notebookID: nb.id, tagIDs: [tag.id])
    let read = try #require(try await lib.note(n.id))
    #expect(read == n)
    #expect(read.title == "Groceries" && read.notebookID == nb.id && read.tagIDs == [tag.id])
    #expect(!read.pinned && read.created == TestLibrary.t0 && read.modified == TestLibrary.t0 && read.trashedAt == nil)
    #expect(try await lib.changes(after: 0).last == ChangeLogEntry(seq: 3, itemID: n.id, itemType: .note, op: .upsert, bodyChanged: true, at: TestLibrary.t0))
}

@Test func createNoteWithGivenIDAndTimes() async throws {
    let lib = try TestLibrary.open()
    let id = ULID(string: "01JC8ZV2VW3XY4ZA5BC6DE7FG8")!
    let n = try await lib.createNote(title: "x", id: id, created: 5, modified: 7)
    #expect(n.id == id && n.created == 5 && n.modified == 7)
}

@Test func bodyBytesAreKeptExactly() async throws {
    let lib = try TestLibrary.open()
    let body = "---\r\ntitle: x\r\n---\r\nCafe\u{301}\u{00A0} 😀  \n"
    let n = try await lib.createNote(title: "Caf\u{E9}", body: body)
    let read = try #require(try await lib.note(n.id))
    #expect(Array(read.body.utf8) == Array(body.utf8))
    #expect(Array(read.title.utf8) == Array("Caf\u{E9}".utf8))
}

@Test func editingOnlyMetadataKeepsModified() async throws {
    let clock = TestClock()
    let lib = try TestLibrary.open(clock: clock)
    let nb = try await lib.createNotebook(name: "A", parentID: nil)
    let tag = try await lib.createTag(name: "t")
    let n = try await lib.createNote(title: "x", body: "one")
    clock.advance(1)
    try await lib.setPinned(n.id, true)
    try await lib.moveNote(n.id, to: nb.id)
    try await lib.setTags(n.id, [tag.id])
    try await lib.trashNote(n.id)
    try await lib.restoreNote(n.id)
    var read = try #require(try await lib.note(n.id))
    #expect(read.modified == TestLibrary.t0)
    #expect(read.pinned && read.notebookID == nb.id && read.tagIDs == [tag.id] && read.trashedAt == nil)
    #expect(try await lib.changes(after: 0).suffix(5).allSatisfy { $0.op == .upsert && !$0.bodyChanged })
    clock.set(TestLibrary.t0 + 5)
    read = try await lib.updateNote(n.id, body: "two")
    #expect(read.modified == TestLibrary.t0 + 5 && read.body == "two")
    #expect(try await lib.changes(after: 0).last?.bodyChanged == true)
    clock.advance(1)
    read = try await lib.updateNote(n.id, title: "y")
    #expect(read.modified == TestLibrary.t0 + 6)
    #expect(try await lib.changes(after: 0).last?.bodyChanged == false)
}

@Test func noOpUpdateWritesNothing() async throws {
    let lib = try TestLibrary.open()
    let n = try await lib.createNote(title: "x", body: "same")
    let count = try await lib.changes(after: 0).count
    let read = try await lib.updateNote(n.id, title: "x", body: "same")
    #expect(read == n)
    try await lib.setPinned(n.id, false)
    try await lib.setTags(n.id, [])
    try await lib.moveNote(n.id, to: nil)
    try await lib.restoreNote(n.id)
    #expect(try await lib.changes(after: 0).count == count)
}

@Test func unknownIDsThrowNotFound() async throws {
    let lib = try TestLibrary.open()
    let ghost = ULID.generate(at: 1)
    #expect(try await lib.note(ghost) == nil)
    await #expect(throws: LibraryError.notFound(ghost)) { try await lib.updateNote(ghost, body: "x") }
    await #expect(throws: LibraryError.notFound(ghost)) { try await lib.trashNote(ghost) }
    await #expect(throws: LibraryError.notFound(ghost)) { try await lib.createNote(notebookID: ghost) }
    await #expect(throws: LibraryError.notFound(ghost)) { try await lib.createNote(tagIDs: [ghost]) }
    let n = try await lib.createNote()
    await #expect(throws: LibraryError.notFound(ghost)) { try await lib.setTags(n.id, [ghost]) }
}

@Test func scopesFilterAndSort() async throws {
    let clock = TestClock()
    let lib = try TestLibrary.open(clock: clock)
    let top = try await lib.createNotebook(name: "Top", parentID: nil)
    let sub = try await lib.createNotebook(name: "Sub", parentID: top.id)
    let tag = try await lib.createTag(name: "t")
    clock.set(TestLibrary.t0 - 10 * day)
    let old = try await lib.createNote(title: "old")
    clock.set(TestLibrary.t0)
    let plain = try await lib.createNote(title: "plain", body: "  hello\n\n  world  ")
    clock.advance(1)
    let inSub = try await lib.createNote(title: "inSub", notebookID: sub.id)
    clock.advance(1)
    let tagged = try await lib.createNote(title: "tagged", tagIDs: [tag.id])
    clock.advance(1)
    let trashed = try await lib.createNote(title: "trashed", notebookID: top.id, tagIDs: [tag.id])
    try await lib.trashNote(trashed.id)
    let pinned = try await lib.createNote(title: "pinned")   // same ms as trashed
    try await lib.setPinned(pinned.id, true)

    #expect(try await lib.notes(in: .all).map(\.id) == [pinned.id, tagged.id, inSub.id, plain.id, old.id])
    #expect(try await lib.notes(in: .recent).map(\.id) == [pinned.id, tagged.id, inSub.id, plain.id])
    #expect(try await lib.notes(in: .pinned).map(\.id) == [pinned.id])
    #expect(try await lib.notes(in: .trash).map(\.id) == [trashed.id])
    #expect(try await lib.notes(in: .notebook(top.id)).map(\.id) == [inSub.id])
    #expect(try await lib.notes(in: .notebook(sub.id)).map(\.id) == [inSub.id])
    #expect(try await lib.notes(in: .tag(tag.id)).map(\.id) == [tagged.id])
    #expect(try await lib.notes(in: .all).first { $0.id == plain.id }?.preview == "hello world")
}

@Test func previewIsCappedAt200Characters() async throws {
    let lib = try TestLibrary.open()
    let n = try await lib.createNote(title: "x", body: String(repeating: "é", count: 500))
    #expect(try await lib.notes(in: .all).first { $0.id == n.id }?.preview.count == 200)
}

@Test func recentIsCappedAt50() async throws {
    let lib = try TestLibrary.open()
    for _ in 0..<55 { _ = try await lib.createNote(title: "n") }
    #expect(try await lib.notes(in: .recent).count == 50)
}

@Test func purgeExpiredTrashRespectsRetention() async throws {
    let clock = TestClock()
    let lib = try TestLibrary.open(clock: clock)
    let n = try await lib.createNote(title: "x")
    try await lib.trashNote(n.id)
    clock.set(TestLibrary.t0 + 30 * day - 1)
    #expect(try await lib.purgeExpiredTrash() == 0)
    clock.set(TestLibrary.t0 + 30 * day)
    #expect(try await lib.purgeExpiredTrash() == 1)
    #expect(try await lib.note(n.id) == nil)
    #expect(try await lib.changes(after: 0).last?.op == .delete)
    let m = try await lib.createNote(title: "y")
    try await lib.trashNote(m.id)
    clock.advance(7 * day)
    #expect(try await lib.purgeExpiredTrash(retentionDays: 7) == 1)
}

@Test func emptyTrashAndDeletePermanently() async throws {
    let lib = try TestLibrary.open()
    let tag = try await lib.createTag(name: "t")
    let a = try await lib.createNote(title: "a", tagIDs: [tag.id])
    let b = try await lib.createNote(title: "b")
    let c = try await lib.createNote(title: "c")
    try await lib.trashNote(a.id)
    try await lib.trashNote(b.id)
    #expect(try await lib.emptyTrash() == 2)
    try await lib.deleteNotePermanently(c.id)
    #expect(try await lib.notes(in: .all).isEmpty)
    #expect(try await lib.notes(in: .trash).isEmpty)
    #expect(try await lib.changes(after: 0).suffix(3).map(\.op) == [.delete, .delete, .delete])
}

@Test func restoreAfterNotebookDeleteGoesToRoot() async throws {
    let lib = try TestLibrary.open()
    let parent = try await lib.createNotebook(name: "P", parentID: nil)
    let child = try await lib.createNotebook(name: "C", parentID: parent.id)
    let n = try await lib.createNote(title: "x", notebookID: child.id)
    let already = try await lib.createNote(title: "y", notebookID: parent.id)
    try await lib.trashNote(already.id)
    let trashedAt = try await lib.note(already.id)?.trashedAt
    try await lib.deleteNotebook(parent.id)
    let trashed = try #require(try await lib.note(n.id))
    #expect(trashed.trashedAt != nil && trashed.notebookID == nil)
    #expect(try await lib.note(already.id)?.trashedAt == trashedAt)
    try await lib.restoreNote(n.id)
    #expect(try await lib.notes(in: .all).map(\.id) == [n.id])
    #expect(try await lib.note(n.id)?.notebookID == nil)
    #expect(try await lib.rowCount("PRAGMA foreign_key_check") == 0)
}

@Test func deletedTagDisappearsFromNotes() async throws {
    let lib = try TestLibrary.open()
    let tag = try await lib.createTag(name: "t")
    let n = try await lib.createNote(title: "x", tagIDs: [tag.id])
    try await lib.deleteTag(tag.id)
    #expect(try await lib.note(n.id)?.tagIDs == [])
}

@Test func failedWriteLeavesNothing() async throws {
    let lib = try TestLibrary.open()
    let n = try await lib.createNote(title: "x", body: "before")
    let count = try await lib.changes(after: 0).count
    await lib.setBeforeCommitHook { throw Boom() }
    await #expect(throws: Boom.self) { try await lib.updateNote(n.id, body: "zebra") }
    await lib.setBeforeCommitHook(nil)
    #expect(try await lib.note(n.id)?.body == "before")
    #expect(try await lib.search("zebra").isEmpty)
    #expect(try await lib.search("before").map(\.note.id) == [n.id])
    #expect(try await lib.changes(after: 0).count == count)
}

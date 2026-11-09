import Testing
@testable import FeatherCore

@Test func createNestedNotebooksThreeLevels() async throws {
    let lib = try TestLibrary.open()
    let top = try await lib.createNotebook(name: "Home", parentID: nil)
    let mid = try await lib.createNotebook(name: "Recipes", parentID: top.id)
    let low = try await lib.createNotebook(name: "Pasta", parentID: mid.id)
    #expect(Set(try await lib.descendants(of: top.id)) == [top.id, mid.id, low.id])
    #expect(try await lib.notebooks().map(\.name) == ["Home", "Pasta", "Recipes"])
    #expect(low.parentID == mid.id && low.created == TestLibrary.t0)
}

@Test func moveIntoOwnDescendantThrowsCycle() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.createNotebook(name: "A", parentID: nil)
    let b = try await lib.createNotebook(name: "B", parentID: a.id)
    await #expect(throws: LibraryError.notebookCycle) { try await lib.moveNotebook(a.id, toParent: b.id) }
    await #expect(throws: LibraryError.notebookCycle) { try await lib.moveNotebook(a.id, toParent: a.id) }
    try await lib.moveNotebook(b.id, toParent: nil)
    #expect(try await lib.notebooks().first { $0.id == b.id }?.parentID == nil)
}

@Test func renameAndMoveBumpModified() async throws {
    let clock = TestClock()
    let lib = try TestLibrary.open(clock: clock)
    let a = try await lib.createNotebook(name: "A", parentID: nil)
    clock.advance(10)
    try await lib.renameNotebook(a.id, to: "Archive")
    let renamed = try await lib.notebooks().first!
    #expect(renamed.name == "Archive" && renamed.modified == TestLibrary.t0 + 10 && renamed.created == TestLibrary.t0)
}

@Test func unknownNotebookThrowsNotFound() async throws {
    let lib = try TestLibrary.open()
    let ghost = ULID.generate(at: 1)
    await #expect(throws: LibraryError.notFound(ghost)) { try await lib.renameNotebook(ghost, to: "x") }
    await #expect(throws: LibraryError.notFound(ghost)) { try await lib.createNotebook(name: "x", parentID: ghost) }
}

@Test func deleteNotebookRemovesSubtree() async throws {
    let lib = try TestLibrary.open()
    let top = try await lib.createNotebook(name: "Home", parentID: nil)
    let mid = try await lib.createNotebook(name: "Recipes", parentID: top.id)
    _ = try await lib.createNotebook(name: "Pasta", parentID: mid.id)
    let other = try await lib.createNotebook(name: "Work", parentID: nil)
    let before = try await lib.changes(after: 0).count
    try await lib.deleteNotebook(top.id)
    #expect(try await lib.notebooks().map(\.id) == [other.id])
    let log = try await lib.changes(after: 0).dropFirst(before)
    #expect(log.map(\.op) == [.delete, .delete, .delete])
    #expect(log.allSatisfy { $0.itemType == .notebook })
}

@Test func everyMutationLogsOnce() async throws {
    let lib = try TestLibrary.open()
    let nb = try await lib.createNotebook(name: "A", parentID: nil)
    try await lib.renameNotebook(nb.id, to: "B")
    let tag = try await lib.createTag(name: "travel")
    try await lib.deleteTag(tag.id)
    let log = try await lib.changes(after: 0)
    #expect(log.map(\.op) == [.upsert, .upsert, .upsert, .delete])
    #expect(log.map(\.itemID) == [nb.id, nb.id, tag.id, tag.id])
    #expect(zip(log, log.dropFirst()).allSatisfy { $0.seq < $1.seq })
    #expect(log.allSatisfy { !$0.bodyChanged && $0.at == TestLibrary.t0 })
    #expect(try await lib.changes(after: log[1].seq).count == 2)
    #expect(try await lib.changes(after: 0, limit: 1).count == 1)
}

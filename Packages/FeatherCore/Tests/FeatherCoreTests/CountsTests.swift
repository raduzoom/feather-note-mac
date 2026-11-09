import Testing
@testable import FeatherCore

@Test func countsMatchScopes() async throws {
    let lib = try TestLibrary.open()
    let top = try await lib.createNotebook(name: "Top", parentID: nil)
    let mid = try await lib.createNotebook(name: "Mid", parentID: top.id)
    let low = try await lib.createNotebook(name: "Low", parentID: mid.id)
    let other = try await lib.createNotebook(name: "Other", parentID: nil)
    _ = try await lib.createNote(title: "root")
    let pinned = try await lib.createNote(title: "pinned", notebookID: top.id)
    try await lib.setPinned(pinned.id, true)
    _ = try await lib.createNote(title: "low", notebookID: low.id)
    _ = try await lib.createNote(title: "mid", notebookID: mid.id)
    let gone = try await lib.createNote(title: "gone", notebookID: low.id)
    try await lib.trashNote(gone.id)

    let c = try await lib.counts()
    #expect(c.all == (try await lib.notes(in: .all)).count)
    #expect(c.pinned == (try await lib.notes(in: .pinned)).count)
    #expect(c.trash == (try await lib.notes(in: .trash)).count)
    for nb in [top, mid, low, other] {
        #expect(c.notebooks[nb.id, default: 0] == (try await lib.notes(in: .notebook(nb.id))).count, "\(nb.name)")
    }
    #expect(c == LibraryCounts(all: 4, pinned: 1, trash: 1, notebooks: [top.id: 3, mid.id: 2, low.id: 1, other.id: 0]))
}

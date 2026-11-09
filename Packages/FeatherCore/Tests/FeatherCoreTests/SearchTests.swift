import Testing
@testable import FeatherCore

private func ids(_ hits: [SearchHit]) -> [ULID] { hits.map(\.note.id) }

@Test func findsByTitleAndBody() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.createNote(title: "Groceries", body: "milk and bread")
    let b = try await lib.createNote(title: "Work", body: "buy groceries later")
    _ = try await lib.createNote(title: "Other", body: "nothing")
    #expect(Set(ids(try await lib.search("groceries"))) == [a.id, b.id])
    #expect(ids(try await lib.search("bread")) == [a.id])
    #expect(ids(try await lib.search("milk bread")) == [a.id])
    #expect(try await lib.search("milk nothing").isEmpty)
}

@Test func diacriticsFold() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.createNote(title: "Café", body: "")
    let b = try await lib.createNote(title: "cafe", body: "")
    let c = try await lib.createNote(title: "x", body: "Cafe\u{301} au lait")
    #expect(Set(ids(try await lib.search("cafe"))) == [a.id, b.id, c.id])
    #expect(Set(ids(try await lib.search("café"))) == [a.id, b.id, c.id])
}

@Test func prefixMatches() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.createNote(title: "Recipe book")
    #expect(ids(try await lib.search("rec")) == [a.id])
}

@Test func filtersByNotebookTreeAndAllTags() async throws {
    let lib = try TestLibrary.open()
    let top = try await lib.createNotebook(name: "Top", parentID: nil)
    let sub = try await lib.createNotebook(name: "Sub", parentID: top.id)
    let t1 = try await lib.createTag(name: "one")
    let t2 = try await lib.createTag(name: "two")
    let inTop = try await lib.createNote(title: "apple", notebookID: top.id, tagIDs: [t1.id])
    let inSub = try await lib.createNote(title: "apple", notebookID: sub.id, tagIDs: [t1.id, t2.id])
    let root = try await lib.createNote(title: "apple")
    #expect(Set(ids(try await lib.search("apple"))) == [inTop.id, inSub.id, root.id])
    #expect(Set(ids(try await lib.search("apple", notebookID: top.id))) == [inTop.id, inSub.id])
    #expect(ids(try await lib.search("apple", notebookID: sub.id)) == [inSub.id])
    #expect(Set(ids(try await lib.search("apple", tagIDs: [t1.id]))) == [inTop.id, inSub.id])
    #expect(ids(try await lib.search("apple", tagIDs: [t1.id, t2.id])) == [inSub.id])
    #expect(ids(try await lib.search("apple", notebookID: top.id, tagIDs: [t2.id])) == [inSub.id])
}

@Test func trashedNotesAreNotFound() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.createNote(title: "apple")
    try await lib.trashNote(a.id)
    #expect(try await lib.search("apple").isEmpty)
}

@Test func editsAndDeletesUpdateTheIndex() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.createNote(title: "apple")
    try await lib.updateNote(a.id, body: "banana")
    #expect(ids(try await lib.search("banana")) == [a.id])
    try await lib.updateNote(a.id, title: "cherry")
    #expect(try await lib.search("apple").isEmpty)
    try await lib.deleteNotePermanently(a.id)
    #expect(try await lib.search("banana").isEmpty)
}

@Test func titleOutranksBody() async throws {
    let lib = try TestLibrary.open()
    let inBody = try await lib.createNote(title: "x", body: "one two three zebra four five six seven")
    let inTitle = try await lib.createNote(title: "zebra", body: "one two three four five six seven eight")
    #expect(ids(try await lib.search("zebra")) == [inTitle.id, inBody.id])
}

@Test func snippetMarksMatches() async throws {
    let lib = try TestLibrary.open()
    _ = try await lib.createNote(title: "x", body: "the weather station logs pressure")
    let hit = try #require(try await lib.search("weather").first)
    #expect(!hit.snippet.contains("\u{2}") && !hit.snippet.contains("\u{3}"))
    #expect(hit.matches.count == 1)
    let r = try #require(hit.matches.first)
    let chars = Array(hit.snippet)
    #expect(String(chars[r]) == "weather")
}

@Test func titleOnlyMatchUsesPreview() async throws {
    let lib = try TestLibrary.open()
    _ = try await lib.createNote(title: "zebra", body: "plain body")
    let hit = try #require(try await lib.search("zebra").first)
    #expect(hit.snippet == "plain body" && hit.matches.isEmpty)
}

@Test func queryWithFTSSyntaxIsLiteral() async throws {
    let lib = try TestLibrary.open()
    let foo = try await lib.createNote(title: "x", body: "foo bar")
    for q in ["\"", "*", "-foo", "AND", "NEAR(", "(", "\"\"", "   ", "a:b", "", "foo\"bar", "OR", "^", "{x}"] {
        _ = try await lib.search(q)
    }
    #expect(ids(try await lib.search("-foo")) == [foo.id])
    #expect(try await lib.search("   ").isEmpty)
}

@Test func ftsQueryBuilding() {
    #expect(Library.ftsQuery("milk bread") == "\"milk\"* \"bread\"*")
    #expect(Library.ftsQuery("a\"b") == "\"a\"\"b\"*")
    #expect(Library.ftsQuery("  ") == nil)
}

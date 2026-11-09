import Testing
@testable import FeatherCore

@Test func tagNamesAreCaseInsensitivelyUnique() async throws {
    let lib = try TestLibrary.open()
    let t = try await lib.createTag(name: "Travel")
    await #expect(throws: LibraryError.duplicateTagName("travel")) { try await lib.createTag(name: "travel") }
    #expect(try await lib.tag(named: "TRAVEL")?.name == "Travel")
    try await lib.renameTag(t.id, to: "TRAVEL")
    #expect(try await lib.tags().map(\.name) == ["TRAVEL"])
    let other = try await lib.createTag(name: "Work")
    await #expect(throws: LibraryError.duplicateTagName("travel")) { try await lib.renameTag(other.id, to: "travel") }
}

@Test func unicodeCaseFolding() async throws {
    let lib = try TestLibrary.open()
    _ = try await lib.createTag(name: "Écoles")
    await #expect(throws: LibraryError.duplicateTagName("écoles")) { try await lib.createTag(name: "écoles") }
}

@Test func emptyTagNameIsInvalid() async throws {
    let lib = try TestLibrary.open()
    await #expect(throws: LibraryError.invalidName) { try await lib.createTag(name: "  ") }
    await #expect(throws: LibraryError.invalidName) { try await lib.createTag(name: "") }
}

@Test func deleteTagRemovesIt() async throws {
    let lib = try TestLibrary.open()
    let t = try await lib.createTag(name: "x")
    try await lib.deleteTag(t.id)
    #expect(try await lib.tags().isEmpty)
    #expect(try await lib.tag(named: "x") == nil)
}

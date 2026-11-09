import Foundation
import Testing
@testable import FeatherCore

private func pragma(_ name: String, at dir: URL) throws -> String {
    let db = try Connection(path: dir.appending(path: "library.sqlite").path)
    let s = try db.prepare("PRAGMA \(name)")
    _ = try s.step()
    return s.text(0)
}

@Test func openCreatesLibraryAndKeepsItsID() throws {
    let dir = TestLibrary.directory()
    let id = try Library.open(at: dir, clock: .fixed(TestLibrary.t0)).id
    let again = try Library.open(at: dir)
    #expect(again.id == id)
    #expect(id.timestamp == TestLibrary.t0)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "attachments").path))
}

@Test func openCreatesMissingDirectory() throws {
    let dir = TestLibrary.directory().appending(path: "nested/Feather Note")
    _ = try Library.open(at: dir)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "library.sqlite").path))
}

@Test func openUsesWALAndVersion1() throws {
    let dir = TestLibrary.directory()
    _ = try Library.open(at: dir)
    #expect(try pragma("journal_mode", at: dir) == "wal")
    #expect(try pragma("user_version", at: dir) == "1")
}

@Test func newerSchemaRefusesToOpen() throws {
    let dir = TestLibrary.directory()
    _ = try Library.open(at: dir)
    do {
        let db = try Connection(path: dir.appending(path: "library.sqlite").path)
        try db.execute("PRAGMA user_version = 2")
    }
    #expect(throws: LibraryError.newerSchema(found: 2, supported: 1)) { try Library.open(at: dir) }
    #expect(try pragma("user_version", at: dir) == "2")
}

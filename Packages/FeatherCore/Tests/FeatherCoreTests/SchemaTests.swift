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
    let dir = TestLibrary.directory().appending(path: "nested/FeatherMark")
    _ = try Library.open(at: dir)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "library.sqlite").path))
}

@Test func openUsesWALAndCurrentVersion() throws {
    let dir = TestLibrary.directory()
    _ = try Library.open(at: dir)
    #expect(try pragma("journal_mode", at: dir) == "wal")
    #expect(try pragma("user_version", at: dir) == String(Schema.version))
}

@Test func newerSchemaRefusesToOpen() throws {
    let dir = TestLibrary.directory()
    _ = try Library.open(at: dir)
    do {
        let db = try Connection(path: dir.appending(path: "library.sqlite").path)
        try db.execute("PRAGMA user_version = \(Schema.version + 1)")
    }
    #expect(throws: LibraryError.newerSchema(found: Schema.version + 1, supported: Schema.version)) { try Library.open(at: dir) }
    #expect(try pragma("user_version", at: dir) == String(Schema.version + 1))
}

@Test func version1LibraryMigratesToCurrent() throws {
    let dir = TestLibrary.directory()
    do {
        let db = try Connection(path: dir.appending(path: "library.sqlite").path)
        try db.execute(Schema.migrations[0])
        try db.execute("PRAGMA user_version = 1")
        try db.execute("INSERT INTO notes (id, title, body, created, modified) VALUES ('01JC8ZQ6V4N1XG2H3K5M7P9R0T', 'kept', 'body', 1, 1)")
    }
    _ = try Library.open(at: dir)
    #expect(try pragma("user_version", at: dir) == String(Schema.version))
    let db = try Connection(path: dir.appending(path: "library.sqlite").path)
    let s = try db.prepare("SELECT count(*) FROM sqlite_master WHERE name = 'notes_state'"); _ = try s.step()
    #expect(s.int64(0) == 1)
    let n = try db.prepare("SELECT title FROM notes"); _ = try n.step()
    #expect(n.text(0) == "kept")
}

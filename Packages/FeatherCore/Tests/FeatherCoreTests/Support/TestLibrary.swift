import Foundation

enum TestLibrary {
    static let t0: Int64 = 1_762_696_320_123

    /// A fresh, empty directory under the temporary folder.
    static func directory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "FeatherCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

import Synchronization
@testable import FeatherCore

/// A clock tests can move forward.
final class TestClock: Sendable {
    let value: Atomic<Int64>
    init(_ start: Int64 = TestLibrary.t0) { value = Atomic(start) }
    var now: Int64 { value.load(ordering: .relaxed) }
    func set(_ ms: Int64) { value.store(ms, ordering: .relaxed) }
    func advance(_ ms: Int64) { value.add(ms, ordering: .relaxed) }
    var libraryClock: LibraryClock { LibraryClock { self.now } }
}

extension TestLibrary {
    static func open(clock: TestClock = TestClock()) throws -> Library {
        try Library.open(at: directory(), clock: clock.libraryClock)
    }
}

extension Library {
    /// Test-only: number of rows a statement returns.
    func rowCount(_ sql: String) throws -> Int {
        try db.all(sql, []) { _ in 1 }.count
    }

    /// Test-only: first column of the first row, as text.
    func scalar(_ sql: String) throws -> String? {
        try db.all(sql, []) { $0.text(0) }.first
    }
}

extension Library {
    /// Test-only: runs raw SQL.
    func execute(_ sql: String) throws {
        try db.execute(sql)
    }
}

struct NoteDraft: Sendable {
    var title: String
    var body: String
    var notebookID: ULID?
    var tagIDs: Set<ULID>
}

extension Library {
    /// Test-only: creates many notes in one transaction (for bulk setup).
    func createInOneTransaction(_ drafts: [NoteDraft]) throws {
        try write { _ in
            for d in drafts { _ = try createNote(title: d.title, body: d.body, notebookID: d.notebookID, tagIDs: d.tagIDs) }
        }
    }
}

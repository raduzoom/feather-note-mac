import Foundation
import Testing
@testable import FeatherCore

@Test func transactionRollsBackOnThrow() throws {
    let db = try Connection(path: ":memory:")
    try db.execute("CREATE TABLE t(x INTEGER)")
    struct Boom: Error {}
    #expect(throws: Boom.self) {
        try db.transaction { try db.execute("INSERT INTO t VALUES (1)"); throw Boom() }
    }
    let s = try db.prepare("SELECT count(*) FROM t")
    _ = try s.step()
    #expect(s.int64(0) == 0)
}

@Test func transactionCommits() throws {
    let db = try Connection(path: ":memory:")
    try db.execute("CREATE TABLE t(x INTEGER)")
    let n: Int = try db.transaction { try db.execute("INSERT INTO t VALUES (1)"); return db.changes }
    #expect(n == 1)
    #expect(db.lastInsertRowID == 1)
}

@Test func textBindKeepsBytes() throws {
    let db = try Connection(path: ":memory:")
    try db.execute("CREATE TABLE t(x TEXT, y BLOB, z INTEGER)")
    let body = "a\r\nCafe\u{301} \u{00A0}😀\u{0}end"
    let ins = try db.prepare("INSERT INTO t VALUES (?, ?, ?)")
    try ins.bind([.text(body), .blob(Data([0, 1, 2])), .null])
    _ = try ins.step()
    let sel = try db.prepare("SELECT x, y, z FROM t")
    #expect(try sel.step())
    #expect(Array(sel.text(0).utf8) == Array(body.utf8))
    #expect(sel.blob(1) == Data([0, 1, 2]))
    #expect(sel.optionalInt64(2) == nil)
    #expect(try sel.step() == false)
}

@Test func badSQLThrowsWithMessage() throws {
    let db = try Connection(path: ":memory:")
    #expect(throws: SQLiteError.self) { try db.execute("SELEC 1") }
}

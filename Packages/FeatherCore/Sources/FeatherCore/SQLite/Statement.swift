import Foundation
import SQLite3

enum SQLValue {
    case null
    case int(Int64)
    case text(String)
    case blob(Data)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Statement {
    private let stmt: OpaquePointer
    private let connection: Connection   // keeps the connection open while the statement lives

    init(_ stmt: OpaquePointer, connection: Connection) {
        self.stmt = stmt
        self.connection = connection
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, i)
            case .int(let v):
                rc = sqlite3_bind_int64(stmt, i, v)
            case .text(let s):
                let utf8 = ContiguousArray(s.utf8)
                rc = utf8.withUnsafeBufferPointer { buf -> Int32 in
                    guard let base = buf.baseAddress, buf.count > 0 else {
                        return sqlite3_bind_text(stmt, i, "", 0, SQLITE_TRANSIENT)
                    }
                    return base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                        sqlite3_bind_text(stmt, i, $0, Int32(buf.count), SQLITE_TRANSIENT)
                    }
                }
            case .blob(let d):
                rc = d.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, i, buf.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(buf.count), SQLITE_TRANSIENT)
                }
            }
            if rc != SQLITE_OK { throw SQLiteError(code: rc, message: connection.errorMessage) }
        }
    }

    /// Returns true when a row is available, false when done.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let message = connection.errorMessage
            sqlite3_reset(stmt)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func reset() { sqlite3_reset(stmt) }

    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }

    func optionalInt64(_ i: Int32) -> Int64? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
    }

    func text(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }

    func optionalText(_ i: Int32) -> String? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : text(i)
    }

    func blob(_ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}

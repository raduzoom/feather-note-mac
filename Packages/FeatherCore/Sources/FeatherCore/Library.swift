import Foundation

/// A Feather Note library on disk: `library.sqlite` plus the `attachments/` folder.
public actor Library {
    public nonisolated let id: ULID
    public nonisolated let directory: URL

    let db: Connection
    let clock: LibraryClock
    private var beforeCommitHook: (@Sendable () throws -> Void)?
    private var inTransaction = false

    public static func open(at directory: URL, clock: LibraryClock = .system) throws -> Library {
        try Library(directory: directory, clock: clock)
    }

    private init(directory: URL, clock: LibraryClock) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try Connection(path: directory.appending(path: "library.sqlite").path)
        // Check the version before anything that writes (WAL switch included).
        let found = try Schema.userVersion(db)
        if found > Schema.version { throw LibraryError.newerSchema(found: found, supported: Schema.version) }
        try db.execute("PRAGMA busy_timeout = 5000")
        try db.execute("PRAGMA journal_mode = WAL")
        // WAL + NORMAL: a killed process never corrupts the file; only power loss can drop the last commit.
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA foreign_keys = ON")
        try Schema.migrate(db)
        try fm.createDirectory(at: directory.appending(path: "attachments"), withIntermediateDirectories: true)

        let id: ULID = try db.transaction {
            let s = try db.prepare("SELECT value FROM library WHERE key = 'id'")
            if try s.step(), let existing = ULID(string: s.text(0)) { return existing }
            let now = clock.now()
            let new = ULID.generate(at: now)
            let ins = try db.prepare("INSERT OR REPLACE INTO library (key, value) VALUES (?, ?)")
            try ins.bind([.text("id"), .text(new.description)]); _ = try ins.step()
            try ins.bind([.text("created"), .text(String(now))]); _ = try ins.step()
            return new
        }
        self.id = id
        self.directory = directory
        self.db = db
        self.clock = clock
    }

    /// Runs `body` in one transaction. The commit hook (tests only) runs just before COMMIT.
    /// A `write` inside another `write` joins the outer transaction.
    func write<T>(_ body: (Connection) throws -> T) throws -> T {
        if inTransaction { return try body(db) }
        inTransaction = true
        defer { inTransaction = false }
        return try db.transaction {
            let result = try body(db)
            try beforeCommitHook?()
            return result
        }
    }

    /// Appends one change-log row. Call only inside `write`.
    func log(_ type: ItemType, _ id: ULID, _ op: ChangeOp, bodyChanged: Bool, in db: Connection) throws {
        let s = try db.prepare("INSERT INTO change_log (item_id, item_type, op, body_changed, at) VALUES (?, ?, ?, ?, ?)")
        try s.bind([.text(id.description), .text(type.rawValue), .text(op.rawValue), .int(bodyChanged ? 1 : 0), .int(clock.now())])
        _ = try s.step()
    }

    @_spi(Testing) public func setBeforeCommitHook(_ hook: (@Sendable () throws -> Void)?) {
        beforeCommitHook = hook
    }
}

extension Library {
    public func changes(after seq: Int64, limit: Int = 500) throws -> [ChangeLogEntry] {
        try db.all("SELECT seq, item_id, item_type, op, body_changed, at FROM change_log WHERE seq > ? ORDER BY seq LIMIT ?",
                   [.int(seq), .int(Int64(limit))]) { s in
            ChangeLogEntry(seq: s.int64(0), itemID: s.ulid(1), itemType: ItemType(rawValue: s.text(2))!,
                           op: ChangeOp(rawValue: s.text(3))!, bodyChanged: s.int64(4) != 0, at: s.int64(5))
        }
    }
}

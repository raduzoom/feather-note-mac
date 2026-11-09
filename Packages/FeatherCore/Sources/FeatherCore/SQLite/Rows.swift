extension Statement {
    /// Binds `values`, steps through every row and maps each one.
    func all<T>(_ values: [SQLValue] = [], _ map: (Statement) throws -> T) throws -> [T] {
        try bind(values)
        var out: [T] = []
        while try step() { out.append(try map(self)) }
        return out
    }

    /// Binds `values` and runs the statement to completion.
    func run(_ values: [SQLValue] = []) throws {
        try bind(values)
        while try step() {}
    }

    func ulid(_ i: Int32) -> ULID { ULID(string: text(i))! }
    func optionalULID(_ i: Int32) -> ULID? { optionalText(i).flatMap(ULID.init(string:)) }
}

extension Connection {
    func all<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (Statement) throws -> T) throws -> [T] {
        try prepare(sql).all(values, map)
    }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        try prepare(sql).run(values)
    }
}

extension SQLValue {
    static func id(_ id: ULID) -> SQLValue { .text(id.description) }
    static func id(_ id: ULID?) -> SQLValue { id.map { .text($0.description) } ?? .null }
}

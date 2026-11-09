import Testing
@testable import FeatherCore

@Test func ulidTextRoundTrip() {
    let id = ULID(string: "01JC8ZQ6V4N1XG2H3K5M7P9R0T")!
    #expect(id.description == "01JC8ZQ6V4N1XG2H3K5M7P9R0T")
    #expect(ULID(string: "01jc8zq6v4n1xg2h3k5m7p9r0t") == id)
    #expect(ULID(bytes: id.bytes) == id)
    #expect(id.bytes.count == 16)
}

@Test func ulidRejectsBadText() {
    #expect(ULID(string: "81JC8ZQ6V4N1XG2H3K5M7P9R0T") == nil)
    #expect(ULID(string: "01JC8ZQ6V4N1XG2H3K5M7P9R0") == nil)
    #expect(ULID(string: "01JC8ZQ6V4N1XG2H3K5M7P9R0U") == nil)
    #expect(ULID(bytes: [UInt8](repeating: 0, count: 15)) == nil)
}

@Test func ulidTimestampIsFirstSixBytes() {
    let id = ULID.generate(at: TestLibrary.t0)
    #expect(id.timestamp == TestLibrary.t0)
    #expect(ULID.generate(at: 1) < ULID.generate(at: 2))
}

@Test func ulidKnownBytes() {
    // 16 zero bytes -> 26 zeros; all 0xFF bytes is out of range for text (first char would be 7, rest Z)
    #expect(ULID(bytes: [UInt8](repeating: 0, count: 16))!.description == String(repeating: "0", count: 26))
    #expect(ULID(bytes: [UInt8](repeating: 0xFF, count: 16))!.description == "7" + String(repeating: "Z", count: 25))
}

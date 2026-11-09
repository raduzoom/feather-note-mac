/// A ULID: 48-bit millisecond timestamp plus 80 random bits (data-model.md "Ids").
public struct ULID: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Always 16 bytes.
    public let bytes: [UInt8]

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    /// Byte -> 5-bit value, 0xFF for bytes outside the alphabet. Lowercase accepted.
    private static let decode: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (i, c) in alphabet.enumerated() {
            table[Int(c)] = UInt8(i)
            if c >= 0x41 && c <= 0x5A { table[Int(c + 0x20)] = UInt8(i) }
        }
        return table
    }()

    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public init?(string: String) {
        let chars = Array(string.utf8)
        guard chars.count == 26 else { return nil }
        var values = [UInt8]()
        values.reserveCapacity(26)
        for c in chars {
            let v = Self.decode[Int(c)]
            guard v != 0xFF else { return nil }
            values.append(v)
        }
        guard values[0] <= 7 else { return nil }
        // 26 chars * 5 bits = 130 bits; the top 2 bits are zero.
        var out = [UInt8](repeating: 0, count: 16)
        var acc: UInt32 = 0
        var bits = 0
        var index = 0
        for (i, v) in values.enumerated() {
            if i == 0 { acc = UInt32(v); bits = 3; continue }   // first char carries 3 bits
            acc = (acc << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out[index] = UInt8((acc >> UInt32(bits)) & 0xFF)
                index += 1
                acc &= (1 << UInt32(bits)) - 1
            }
        }
        self.bytes = out
    }

    public var description: String {
        var out = [UInt8]()
        out.reserveCapacity(26)
        // first char: top 3 bits of byte 0
        out.append(Self.alphabet[Int(bytes[0] >> 5)])
        var acc = UInt32(bytes[0] & 0x1F)
        var bits = 5
        for b in bytes.dropFirst() {
            acc = (acc << 8) | UInt32(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(Self.alphabet[Int((acc >> UInt32(bits)) & 0x1F)])
            }
            acc &= (1 << UInt32(bits)) - 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Milliseconds since the Unix epoch, from the first 6 bytes.
    public var timestamp: Int64 {
        bytes.prefix(6).reduce(Int64(0)) { ($0 << 8) | Int64($1) }
    }

    public static func generate(at ms: Int64, using rng: inout some RandomNumberGenerator) -> ULID {
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { b[i] = UInt8((ms >> Int64(8 * (5 - i))) & 0xFF) }
        for i in 6..<16 { b[i] = UInt8.random(in: 0...255, using: &rng) }
        return ULID(bytes: b)!
    }

    public static func generate(at ms: Int64) -> ULID {
        var rng = SystemRandomNumberGenerator()
        return generate(at: ms, using: &rng)
    }

    public static func < (lhs: ULID, rhs: ULID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}

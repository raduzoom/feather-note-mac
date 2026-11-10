import Foundation

/// The 16-byte recovery key and its text form (crypto.md "Recovery key"): 128 key bits plus a 12-bit checksum,
/// 28 Crockford base32 characters shown as 7 groups of 4.
public struct RecoveryKey: Equatable, Sendable {
    public let bytes: Data

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".unicodeScalars)
    /// What users type or paste between groups.
    static let separators: Set<UInt32> = [0x09, 0x0A, 0x0D, 0x20, 0xA0, 0x2D, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2212]

    public static func generate() -> RecoveryKey { RecoveryKey(checked: Sodium.random(16)) }

    public init(bytes: Data) throws {
        try InvalidArgument.check(bytes, "recoveryKey", 16)
        self.init(checked: bytes)
    }

    private init(checked bytes: Data) { self.bytes = Data(bytes) }

    /// Parses typed or pasted text in the spec's order; any failure is `recoveryKeyTypo`.
    public init(parsing text: String) throws {
        var values: [UInt8] = []
        for scalar in text.unicodeScalars where !Self.separators.contains(scalar.value) {
            var v = scalar.value
            if v >= 0x61 && v <= 0x7A { v -= 0x20 }   // ASCII a–z only
            switch v {
            case 0x4F: v = 0x30            // O -> 0
            case 0x49, 0x4C: v = 0x31      // I, L -> 1
            default: break
            }
            guard let index = Self.alphabet.firstIndex(where: { $0.value == v }) else { throw CryptoError.recoveryKeyTypo }
            values.append(UInt8(index))
            guard values.count <= 28 else { throw CryptoError.recoveryKeyTypo }
        }
        guard values.count == 28 else { throw CryptoError.recoveryKeyTypo }
        // 140 bits, most significant first: 128 key bits, then the 12-bit checksum
        var bits: [UInt8] = []
        for v in values { for shift in stride(from: 4, through: 0, by: -1) { bits.append((v >> UInt8(shift)) & 1) } }
        var key = Data(count: 16)
        for i in 0..<128 where bits[i] == 1 { key[i / 8] |= 0x80 >> UInt8(i % 8) }
        let checksum = bits[128...].reduce(0) { ($0 << 1) | Int($1) }
        guard checksum == Self.checksum(key) else { throw CryptoError.recoveryKeyTypo }
        self.bytes = key
    }

    /// First 12 bits of unkeyed BLAKE2b-256 of the key.
    static func checksum(_ key: Data) -> Int {
        let h = Sodium.blake2b(key, key: nil)
        return Int(h[0]) << 4 | Int(h[1]) >> 4
    }

    /// `XXXX-XXXX-…`, 7 groups of 4, uppercase.
    public var text: String {
        var bits: [UInt8] = []
        for byte in bytes { for shift in stride(from: 7, through: 0, by: -1) { bits.append((byte >> UInt8(shift)) & 1) } }
        let checksum = Self.checksum(bytes)
        for shift in stride(from: 11, through: 0, by: -1) { bits.append(UInt8((checksum >> shift) & 1)) }
        var chars: [Character] = []
        for group in stride(from: 0, to: 140, by: 5) {
            let v = bits[group..<group + 5].reduce(0) { ($0 << 1) | Int($1) }
            chars.append(Character(Self.alphabet[v]))
        }
        return stride(from: 0, to: 28, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// Wraps the master key (kind `recovery`).
    public var kek: Data { Sodium.blake2b(Data("feather/v1/recovery-kek".utf8), key: bytes) }
    /// Signs in for recovery.
    public var authKey: Data { Sodium.blake2b(Data("feather/v1/recovery-auth".utf8), key: bytes) }
}

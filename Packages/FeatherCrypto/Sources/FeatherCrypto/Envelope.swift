import FeatherCore
import Foundation

/// What an envelope holds: byte 1 of its header. Other values are reserved.
public enum EnvelopePart: UInt8, Sendable {
    case metadata = 1
    case noteBody = 2
    case attachment = 3
}

/// The content envelope (crypto.md "Content envelope"): a 34-byte header, then the plaintext in 65,536-byte
/// chunks, each XChaCha20-Poly1305 with nonce `nonce_prefix || uint64_be(i)` and associated data `header || final`.
public enum Envelope {
    public static let chunkSize = 65_536
    static let headerLength = 34
    static let format: UInt8 = 0x01
    static var sealedChunk: Int { chunkSize + Sodium.tagBytes }

    public static func seal(_ plaintext: Data, part: EnvelopePart, itemID: ULID, itemKey: Data) throws -> Data {
        try seal(plaintext, part: part, itemID: itemID, itemKey: itemKey, noncePrefix: Sodium.random(16))
    }

    static func seal(_ plaintext: Data, part: EnvelopePart, itemID: ULID, itemKey: Data, noncePrefix: Data) throws -> Data {
        try InvalidArgument.check(itemKey, "itemKey", 32)
        try InvalidArgument.check(noncePrefix, "noncePrefix", 16)
        let header = Data([format, part.rawValue]) + itemID.bytes + noncePrefix
        let plaintext = Data(plaintext)
        let chunks = max(1, (plaintext.count + chunkSize - 1) / chunkSize)
        var out = Data(capacity: headerLength + plaintext.count + Sodium.tagBytes * chunks)
        out += header
        for i in 0..<chunks {
            let start = i * chunkSize
            let chunk = plaintext[start..<min(start + chunkSize, plaintext.count)]
            out += Sodium.seal(chunk, ad: header + [i == chunks - 1 ? 1 : 0], nonce: nonce(noncePrefix, i), key: itemKey)
        }
        return out
    }

    /// The plaintext, decoded in crypto.md's six steps. Nothing is returned unless every chunk authenticates.
    public static func open(_ envelope: Data, part: EnvelopePart, itemID: ULID, itemKey: Data) throws -> Data {
        try InvalidArgument.check(itemKey, "itemKey", 32)
        let e = Data(envelope)
        guard e.count >= headerLength + Sodium.tagBytes, e[0] == format else { throw CryptoError.malformedEnvelope }
        guard e[1] == part.rawValue, Array(e[2..<18]) == itemID.bytes else { throw CryptoError.authenticationFailed }
        let header = e[0..<headerLength]
        let prefix = e[18..<headerLength]
        let n = e.count - headerLength
        let chunks = (n + sealedChunk - 1) / sealedChunk
        guard n - sealedChunk * (chunks - 1) >= Sodium.tagBytes else { throw CryptoError.malformedEnvelope }
        var plaintext = Data(capacity: n - Sodium.tagBytes * chunks)
        for i in 0..<chunks {
            let start = headerLength + i * sealedChunk
            let chunk = e[start..<min(start + sealedChunk, e.count)]
            guard let clear = Sodium.open(chunk, ad: header + [i == chunks - 1 ? 1 : 0], nonce: nonce(prefix, i), key: itemKey)
            else { throw CryptoError.authenticationFailed }
            plaintext += clear
        }
        return plaintext
    }

    static func nonce(_ prefix: Data, _ index: Int) -> Data {
        var be = UInt64(index).bigEndian
        return prefix + withUnsafeBytes(of: &be) { Data($0) }
    }
}

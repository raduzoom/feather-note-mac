import Foundation

/// Which key wrapped the master key: byte 1 of a wrapped key.
public enum WrapKind: UInt8, Sendable {
    case password = 1
    case recovery = 2
}

/// The 32-byte master key and its 74-byte wrapped form (crypto.md "Master key wrapping"):
/// `0x01 || kind || nonce (24) || XChaCha20-Poly1305(master key) with tag (48)`, associated data `version || kind`.
public enum MasterKey {
    static let version: UInt8 = 0x01
    static let wrappedLength = 74

    public static func generate() -> Data { Sodium.random(32) }

    public static func wrap(_ masterKey: Data, kind: WrapKind, key: Data) throws -> Data {
        try wrap(masterKey, kind: kind, key: key, nonce: Sodium.random(Sodium.nonceBytes))
    }

    static func wrap(_ masterKey: Data, kind: WrapKind, key: Data, nonce: Data) throws -> Data {
        try InvalidArgument.check(masterKey, "masterKey", 32)
        try InvalidArgument.check(key, "key", 32)
        try InvalidArgument.check(nonce, "nonce", Sodium.nonceBytes)
        let header = Data([version, kind.rawValue])
        return header + nonce + Sodium.seal(masterKey, ad: header, nonce: nonce, key: key)
    }

    /// The master key. A wrapped value of the wrong length, version or kind, or one that doesn't decrypt with
    /// `key`, is an authentication failure: users see "wrong password" whatever the cause.
    public static func unwrap(_ wrapped: Data, kind: WrapKind, key: Data) throws -> Data {
        try InvalidArgument.check(key, "key", 32)
        let w = Data(wrapped)   // index from 0, whatever slice was passed
        guard w.count == wrappedLength, w[0] == version, w[1] == kind.rawValue,
              let master = Sodium.open(w[26...], ad: w[0..<2], nonce: w[2..<26], key: key)
        else { throw CryptoError.authenticationFailed }
        return master
    }
}

import Foundation

/// `kek` wraps the master key; `authKey` signs in. Both are keyed BLAKE2b of `root` (crypto.md "Key derivations").
public struct PasswordKeys: Sendable, Equatable {
    public let kek: Data
    public let authKey: Data

    static func derive(root: Data) throws -> PasswordKeys {
        try InvalidArgument.check(root, "root", 32)
        return PasswordKeys(kek: Sodium.blake2b(Data("feather/v1/password-kek".utf8), key: root),
                            authKey: Sodium.blake2b(Data("feather/v1/auth".utf8), key: root))
    }
}

/// Passwords as crypto.md "Normalization" fixes them: NFC, then UTF-8; no trimming, no case change.
public enum Password {
    public static func normalized(_ password: String) -> Data {
        Data(password.precomposedStringWithCanonicalMapping.utf8)
    }

    /// At least 10 Unicode code points after NFC, required before account creation.
    public static func meetsMinimum(_ password: String) -> Bool {
        password.precomposedStringWithCanonicalMapping.unicodeScalars.count >= 10
    }
}

/// Argon2id parameters, stored with the account and returned by the server at sign-in.
public struct Argon2Params: Codable, Equatable, Sendable {
    public var alg: String
    public var t: UInt32
    public var mKiB: UInt32
    public var p: UInt32

    /// The field names of sync-protocol.openapi.yaml "Kdf".
    enum CodingKeys: String, CodingKey {
        case alg, t, mKiB = "m_kib", p
    }

    public init(alg: String, t: UInt32, mKiB: UInt32, p: UInt32) {
        self.alg = alg
        self.t = t
        self.mKiB = mKiB
        self.p = p
    }

    /// The only parameters `argon2id13` has. Stronger ones come under a new algorithm id, so anything else is
    /// refused before hashing (a server can't make the client allocate gigabytes).
    public static let v1 = Argon2Params(alg: "argon2id13", t: 3, mKiB: 262144, p: 1)
}

extension PasswordKeys {
    /// `root`: Argon2id of the normalized password (crypto.md "Password derivation").
    static func root(password: String, salt: Data, params: Argon2Params) throws -> Data {
        guard params == .v1 else { throw InvalidArgument.unsupportedParameters }
        try InvalidArgument.check(salt, "salt", 16)
        return Sodium.argon2id(password: Password.normalized(password), salt: salt,
                               opsLimit: UInt64(params.t), memLimit: Int(params.mKiB) * 1024)
    }

    public static func derive(password: String, salt: Data, params: Argon2Params) throws -> PasswordKeys {
        try derive(root: root(password: password, salt: salt, params: params))
    }
}

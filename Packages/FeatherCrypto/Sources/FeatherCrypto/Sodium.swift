import Clibsodium
import Foundation

/// The only code that calls libsodium. It exposes exactly the primitives crypto.md "Primitives" allows.
enum Sodium {
    /// `sodium_init` once, before any call; it returns 1 when already initialised.
    private static let ready: Bool = {
        precondition(sodium_init() >= 0, "libsodium failed to initialise")
        return true
    }()

    static let tagBytes = 16
    static let nonceBytes = 24

    /// Bytes from the platform CSPRNG.
    static func random(_ count: Int) -> Data {
        _ = ready
        var out = Data(count: count)
        out.withUnsafeMutableBytes { randombytes_buf($0.baseAddress!, count) }
        return out
    }

    /// Argon2id v1.3, 32-byte output. Callers check the parameters first (Password.swift).
    static func argon2id(password: Data, salt: Data, opsLimit: UInt64, memLimit: Int) -> Data {
        _ = ready
        precondition(salt.count == Int(crypto_pwhash_SALTBYTES))
        var out = Data(count: 32)
        // an empty password still needs a valid pointer; one spare byte that isn't counted
        let passwordBytes = password.map { CChar(bitPattern: $0) } + [0]
        let rc = out.withUnsafeMutableBytes { o in
            salt.withUnsafeBytes { s in
                crypto_pwhash(o.bindMemory(to: UInt8.self).baseAddress!, 32, passwordBytes, UInt64(password.count),
                              s.bindMemory(to: UInt8.self).baseAddress!, opsLimit, memLimit, crypto_pwhash_ALG_ARGON2ID13)
            }
        }
        precondition(rc == 0, "Argon2id ran out of memory")
        return out
    }

    /// BLAKE2b with a 32-byte output; keyed when `key` is given (plain keyed BLAKE2b, not crypto_kdf).
    static func blake2b(_ message: Data, key: Data?) -> Data {
        _ = ready
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { o in
            message.withUnsafeBytes { m in
                if let key {
                    key.withUnsafeBytes { k in
                        _ = crypto_generichash(o.bindMemory(to: UInt8.self).baseAddress!, 32, m.bindMemory(to: UInt8.self).baseAddress,
                                               UInt64(message.count), k.bindMemory(to: UInt8.self).baseAddress, key.count)
                    }
                } else {
                    _ = crypto_generichash(o.bindMemory(to: UInt8.self).baseAddress!, 32, m.bindMemory(to: UInt8.self).baseAddress,
                                           UInt64(message.count), nil, 0)
                }
            }
        }
        return out
    }

    /// XChaCha20-Poly1305 (IETF): ciphertext followed by the 16-byte tag.
    static func seal(_ plaintext: Data, ad: Data, nonce: Data, key: Data) -> Data {
        _ = ready
        precondition(nonce.count == nonceBytes && key.count == 32)
        var out = Data(count: plaintext.count + tagBytes)
        var outLength: UInt64 = 0
        out.withUnsafeMutableBytes { o in
            plaintext.withUnsafeBytes { m in
                ad.withUnsafeBytes { a in
                    nonce.withUnsafeBytes { n in
                        key.withUnsafeBytes { k in
                            _ = crypto_aead_xchacha20poly1305_ietf_encrypt(
                                o.bindMemory(to: UInt8.self).baseAddress!, &outLength,
                                m.bindMemory(to: UInt8.self).baseAddress, UInt64(plaintext.count),
                                a.bindMemory(to: UInt8.self).baseAddress, UInt64(ad.count), nil,
                                n.bindMemory(to: UInt8.self).baseAddress!, k.bindMemory(to: UInt8.self).baseAddress!)
                        }
                    }
                }
            }
        }
        return out
    }

    /// The plaintext, or nil when authentication fails.
    static func open(_ ciphertext: Data, ad: Data, nonce: Data, key: Data) -> Data? {
        _ = ready
        precondition(nonce.count == nonceBytes && key.count == 32)
        guard ciphertext.count >= tagBytes else { return nil }
        var out = Data(count: ciphertext.count - tagBytes)
        var outLength: UInt64 = 0
        let rc = out.withUnsafeMutableBytes { o in
            ciphertext.withUnsafeBytes { c in
                ad.withUnsafeBytes { a in
                    nonce.withUnsafeBytes { n in
                        key.withUnsafeBytes { k in
                            crypto_aead_xchacha20poly1305_ietf_decrypt(
                                o.bindMemory(to: UInt8.self).baseAddress, &outLength, nil,
                                c.bindMemory(to: UInt8.self).baseAddress!, UInt64(ciphertext.count),
                                a.bindMemory(to: UInt8.self).baseAddress, UInt64(ad.count),
                                n.bindMemory(to: UInt8.self).baseAddress!, k.bindMemory(to: UInt8.self).baseAddress!)
                        }
                    }
                }
            }
        }
        return rc == 0 ? out : nil
    }
}

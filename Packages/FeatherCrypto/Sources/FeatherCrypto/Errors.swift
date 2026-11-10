/// Failures on data from a server, a file or the user: the three kinds in crypto.md "Errors".
public enum CryptoError: Error, Equatable, Sendable {
    /// Wrong key or kind, a chunk that fails, an envelope for another item or part. No plaintext is returned.
    case authenticationFailed
    /// Too short, an unknown format byte, or a last chunk shorter than a tag.
    case malformedEnvelope
    /// Recovery key text with a wrong length, a character outside the alphabet, or a checksum mismatch.
    case recoveryKeyTypo
}

/// A caller's programming error, rejected before any crypto runs. Not one of the three kinds.
public enum InvalidArgument: Error, Equatable, Sendable {
    case length(name: String, expected: Int, actual: Int)
    /// Argon2id parameters other than the ones this version knows (crypto.md "Password derivation").
    case unsupportedParameters
    /// Fewer than 10 code points after NFC (crypto.md "Normalization").
    case passwordTooShort

    static func check(_ data: some Collection, _ name: String, _ expected: Int) throws(InvalidArgument) {
        guard data.count == expected else { throw .length(name: name, expected: expected, actual: data.count) }
    }
}

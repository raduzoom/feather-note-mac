import Foundation
import Testing
@testable import FeatherCrypto

@Suite struct PasswordTests {
    @Test func reproducesArgon2Vectors() throws {
        let cases = try Vectors.cases("argon2id")
        #expect(cases.count == 3)
        for c in cases {
            #expect(Password.normalized(c["password"] as! String).hex == c["password_utf8_nfc"] as! String)
            let params = Argon2Params(alg: "argon2id13", t: UInt32(c["t"] as! Int), mKiB: UInt32(c["m_kib"] as! Int), p: UInt32(c["p"] as! Int))
            #expect(params == .v1)
            let root = try PasswordKeys.root(password: c["password"] as! String, salt: Data(hex: c["salt"] as! String), params: params)
            #expect(root.hex == c["root"] as! String, "\(c["name"]!)")
        }
    }

    @Test func unsupportedParametersRejectedBeforeHashing() {   // Review Focus 1
        let salt = Data(count: 16)
        for bad in [Argon2Params(alg: "argon2id13", t: 3, mKiB: 4_194_304, p: 1), Argon2Params(alg: "argon2id13", t: 3, mKiB: 262144, p: 4),
                    Argon2Params(alg: "argon2id13", t: 1, mKiB: 262144, p: 1), Argon2Params(alg: "scrypt", t: 3, mKiB: 262144, p: 1)] {
            #expect(throws: InvalidArgument.unsupportedParameters) { try PasswordKeys.derive(password: "x", salt: salt, params: bad) }
        }
        #expect(throws: InvalidArgument.length(name: "salt", expected: 16, actual: 8)) {
            try PasswordKeys.derive(password: "x", salt: Data(count: 8), params: .v1)
        }
    }

    @Test func paramsUseTheProtocolsFieldNames() throws {   // sync-protocol.openapi.yaml "Kdf"
        let json = Data(#"{"alg":"argon2id13","t":3,"m_kib":262144,"p":1}"#.utf8)
        #expect(try JSONDecoder().decode(Argon2Params.self, from: json) == .v1)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Argon2Params.v1)) as! [String: Any]
        #expect(Set(encoded.keys) == ["alg", "t", "m_kib", "p"])
    }

    @Test func noTrimmingNoCaseChange() {
        #expect(Password.normalized(" Pass ") == Data(" Pass ".utf8))
    }

    @Test func minimumCountsCodePointsAfterNFC() {
        #expect(!Password.meetsMinimum("e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}"))   // 10 scalars typed, 5 after NFC
        #expect(Password.meetsMinimum("éééééééééé"))
        #expect(!Password.meetsMinimum("123456789"))
    }
}

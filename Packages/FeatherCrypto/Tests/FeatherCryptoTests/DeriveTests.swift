import Foundation
import Testing
import FeatherCore
@testable import FeatherCrypto

@Suite struct DeriveTests {
    @Test func derivesEveryCase() throws {
        let cases = try Vectors.cases("derive")
        #expect(cases.count == 4)
        for c in cases {
            switch c["kind"] as! String {
            case "password":
                let k = try PasswordKeys.derive(root: Data(hex: c["root"] as! String))
                #expect(k.kek.hex == c["kek"] as! String && k.authKey.hex == c["auth_key"] as! String)
            case "item":
                let id = try #require(ULID(string: c["item_id"] as! String))
                #expect(Data(id.bytes).hex == c["item_id_bytes"] as! String)
                #expect(try ItemKey.derive(masterKey: Data(hex: c["master_key"] as! String), itemID: id).hex == c["item_key"] as! String)
            case "recovery":
                let k = try RecoveryKey(bytes: Data(hex: c["recovery_key"] as! String))
                #expect(k.kek.hex == c["recovery_kek"] as! String && k.authKey.hex == c["recovery_auth_key"] as! String)
            default: Issue.record("unknown kind in \(c["name"]!)")
            }
        }
    }

    @Test func wrongKeyLengthsAreArguments() {
        #expect(throws: InvalidArgument.length(name: "root", expected: 32, actual: 31)) { try PasswordKeys.derive(root: Data(count: 31)) }
        #expect(throws: InvalidArgument.length(name: "masterKey", expected: 32, actual: 0)) {
            try ItemKey.derive(masterKey: Data(), itemID: ULID(bytes: [UInt8](repeating: 0, count: 16))!)
        }
    }

    @Test func plainBlake2bNotKDF() {   // unkeyed BLAKE2b-256 of "abc" (RFC 7693 reference implementation)
        #expect(Sodium.blake2b(Data("abc".utf8), key: nil).hex == "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
    }
}

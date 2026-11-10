import Foundation
import Testing
@testable import FeatherCrypto

@Suite struct WrapTests {
    @Test func reproducesWrapVectors() throws {
        let cases = try Vectors.cases("wrap")
        #expect(cases.count == 4)
        for c in cases {
            let kind: WrapKind = c["kind"] as! String == "password" ? .password : .recovery
            let key = Data(hex: c["wrapping_key"] as! String), wrapped = Data(hex: c["wrapped"] as! String)
            if let error = c["error"] as? String {
                #expect(error == "authentication_failed")
                #expect(throws: CryptoError.authenticationFailed, "\(c["name"]!)") { try MasterKey.unwrap(wrapped, kind: kind, key: key) }
            } else {
                let master = Data(hex: c["master_key"] as! String)
                #expect(try MasterKey.wrap(master, kind: kind, key: key, nonce: Data(hex: c["nonce"] as! String)) == wrapped)
                #expect(try MasterKey.unwrap(wrapped, kind: kind, key: key) == master)
            }
        }
    }

    @Test func everyFlippedByteFailsUnwrap() throws {   // Review Focus 3
        let c = try Vectors.cases("wrap")[0]
        let key = Data(hex: c["wrapping_key"] as! String), wrapped = Data(hex: c["wrapped"] as! String)
        for i in 0..<wrapped.count {
            var bad = wrapped
            bad[i] ^= 0x01
            #expect(throws: CryptoError.authenticationFailed, "byte \(i)") { try MasterKey.unwrap(bad, kind: .password, key: key) }
        }
        #expect(throws: CryptoError.authenticationFailed) { try MasterKey.unwrap(wrapped.dropLast(), kind: .password, key: key) }
        #expect(throws: CryptoError.authenticationFailed) { try MasterKey.unwrap(wrapped + [0], kind: .password, key: key) }
    }

    @Test func freshNonceEachWrap() throws {
        let m = MasterKey.generate(), k = Data(count: 32)
        #expect(m.count == 32 && m != Data(count: 32))
        #expect(try MasterKey.wrap(m, kind: .password, key: k) != MasterKey.wrap(m, kind: .password, key: k))
    }
}

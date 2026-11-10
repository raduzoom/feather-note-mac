import Foundation
import Testing
@testable import FeatherCrypto

@Suite struct RecoveryTests {
    @Test func reproducesRecoveryVectors() throws {
        let cases = try Vectors.cases("recovery")
        #expect(cases.count == 20)
        for c in cases {
            if c["kind"] as! String == "format" {
                #expect(try RecoveryKey(bytes: Data(hex: c["recovery_key"] as! String)).text == c["text"] as! String)
            } else if let error = c["error"] as? String {
                #expect(error == "recovery_key_typo")
                #expect(throws: CryptoError.recoveryKeyTypo, "\(c["name"]!)") { try RecoveryKey(parsing: c["input"] as! String) }
            } else {
                #expect(try RecoveryKey(parsing: c["input"] as! String).bytes.hex == c["recovery_key"] as! String, "\(c["name"]!)")
            }
        }
    }

    @Test func generatedKeysRoundTrip() throws {
        for _ in 0..<200 {
            let k = RecoveryKey.generate()
            #expect(try RecoveryKey(parsing: k.text) == k)
        }
    }

    @Test func nonASCIILettersAreTypos() {   // step 2: no Unicode case mapping
        #expect(throws: CryptoError.recoveryKeyTypo) { try RecoveryKey(parsing: "DT1H-530K-CKSM-H797-JXHZ-0F5C-8F9\u{FF30}") }   // fullwidth P
    }
}

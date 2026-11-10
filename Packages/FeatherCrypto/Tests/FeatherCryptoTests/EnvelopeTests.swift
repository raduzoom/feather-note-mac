import CryptoKit
import FeatherCore
import Foundation
import Testing
@testable import FeatherCrypto

@Suite struct EnvelopeTests {
    func part(_ n: Any?) -> EnvelopePart { EnvelopePart(rawValue: UInt8(n as! Int))! }
    func id(_ c: [String: Any]) -> ULID { ULID(string: c["item_id"] as! String)! }
    func key(_ c: [String: Any]) -> Data { Data(hex: c["item_key"] as! String) }

    /// A positive case's envelope, sealed again from its inputs (the large ones are given only as SHA-256).
    func reseal(_ c: [String: Any]) throws -> Data {
        let plaintext = c["plaintext"].map { Data(hex: $0 as! String) } ?? pattern(c["length"] as! Int)
        return try Envelope.seal(plaintext, part: part(c["part"]), itemID: id(c), itemKey: key(c), noncePrefix: Data(hex: c["nonce_prefix"] as! String))
    }

    /// test-vectors/README.md "Mutations".
    func mutate(_ envelope: Data, _ name: String) -> Data {
        let header = envelope.prefix(34), body = Data(envelope.dropFirst(34))
        let s = 65_552, n = body.count, k = (n + s - 1) / s
        switch name {
        case "drop_last_chunk": return header + body[0..<s * (k - 1)]
        case "swap_chunks_0_1": return header + body[s..<2 * s] + body[0..<s] + body[(2 * s)..<n]
        case "cut_last_chunk_to_10_bytes": return header + body[0..<s * (k - 1)] + body[(n - 10)..<n]
        default: Issue.record("unknown mutation \(name)"); return envelope
        }
    }

    func error(_ name: Any?) -> CryptoError {
        switch name as! String {
        case "authentication_failed": return .authenticationFailed
        case "malformed_envelope": return .malformedEnvelope
        default: Issue.record("unknown error \(name!)"); return .recoveryKeyTypo
        }
    }

    @Test func reproducesEnvelopeVectors() throws {
        let cases = try Vectors.cases("envelope")
        #expect(cases.count == 16)
        let byName = Dictionary(uniqueKeysWithValues: cases.map { ($0["name"] as! String, $0) })
        for c in cases {
            let name = c["name"] as! String
            if c["error"] == nil {
                let sealed = try reseal(c)
                if let hex = c["envelope"] as? String {
                    #expect(sealed.hex == hex, "\(name)")
                    #expect(try Envelope.open(sealed, part: part(c["part"]), itemID: id(c), itemKey: key(c)) == Data(hex: c["plaintext"] as! String))
                } else {
                    #expect(sealed.count == c["envelope_length"] as! Int, "\(name)")
                    #expect(Data(SHA256.hash(data: sealed)).hex == c["envelope_sha256"] as! String, "\(name)")
                    #expect(try Envelope.open(sealed, part: part(c["part"]), itemID: id(c), itemKey: key(c)) == pattern(c["length"] as! Int))
                }
            } else {
                let envelope: Data
                if let hex = c["envelope"] as? String {
                    envelope = Data(hex: hex)
                } else {
                    let source = try #require(byName[c["derived_from"] as! String])
                    envelope = mutate(try reseal(source), c["mutation"] as! String)
                }
                #expect(throws: error(c["error"]), "\(name)") {
                    try Envelope.open(envelope, part: part(c["expected_part"]), itemID: id(c), itemKey: key(c))
                }
            }
        }
    }

    func helloWorld() throws -> (Data, ULID, Data) {
        let c = try #require(try Vectors.cases("envelope").first { $0["name"] as! String == "hello_world" })
        return (Data(hex: c["envelope"] as! String), id(c), key(c))
    }

    @Test func everyFlippedByteFailsOpen() throws {   // Review Focus 3
        let (env, id, key) = try helloWorld()
        for i in 0..<env.count {
            var bad = env
            bad[i] ^= 0x01
            let expected: CryptoError = i == 0 ? .malformedEnvelope : .authenticationFailed
            #expect(throws: expected, "byte \(i)") { try Envelope.open(bad, part: .noteBody, itemID: id, itemKey: key) }
        }
    }

    @Test func shortAndBoundaryLengthsNeverCrash() throws {   // Review Focus 4
        let (env, id, key) = try helloWorld()
        for n in 0..<50 {
            #expect(throws: CryptoError.malformedEnvelope, "length \(n)") { try Envelope.open(env.prefix(n), part: .noteBody, itemID: id, itemKey: key) }
        }
        let big = try Envelope.seal(pattern(65_536 * 2 + 5), part: .attachment, itemID: id, itemKey: key)
        // body = n - 34; the last chunk is what's left after full 65,552-byte chunks
        let cuts: [(Int, CryptoError)] = [(34 + 65_551, .authenticationFailed), (34 + 65_552, .authenticationFailed),
                                          (34 + 65_552 + 15, .malformedEnvelope), (34 + 65_552 + 16, .authenticationFailed),
                                          (big.count - 1, .authenticationFailed)]
        for (n, error) in cuts {
            #expect(throws: error, "length \(n)") { try Envelope.open(big.prefix(n), part: .attachment, itemID: id, itemKey: key) }
        }
    }

    @Test func sealingTwiceGivesDifferentEnvelopes() throws {   // Review Focus 5
        let (_, id, key) = try helloWorld()
        let a = try Envelope.seal(Data("x".utf8), part: .metadata, itemID: id, itemKey: key)
        let b = try Envelope.seal(Data("x".utf8), part: .metadata, itemID: id, itemKey: key)
        #expect(a != b && a.prefix(18) == b.prefix(18))
    }
}

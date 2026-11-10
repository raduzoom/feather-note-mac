import Foundation

/// The crypto test vectors in the universal repo, checked out next to `mac` (or `FEATHER_TEST_VECTORS`).
/// A missing folder fails the tests: they must never pass without the vectors.
enum Vectors {
    struct Missing: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "Test vectors not found at \(path). Check out feather-note-universal next to mac, or set FEATHER_TEST_VECTORS."
        }
    }

    static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["FEATHER_TEST_VECTORS"] { return URL(fileURLWithPath: path) }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }   // Vectors.swift, FeatherCryptoTests, Tests, FeatherCrypto, Packages, mac
        return url.appending(path: "universal/test-vectors")
    }

    static func cases(_ file: String) throws -> [[String: Any]] {
        let url = folder.appending(path: file + ".json")
        guard let data = try? Data(contentsOf: url) else { throw Missing(path: url.path) }
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return object["cases"] as! [[String: Any]]
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// A large vector plaintext: byte i is i mod 251.
func pattern(_ length: Int) -> Data { Data((0..<length).map { UInt8($0 % 251) }) }

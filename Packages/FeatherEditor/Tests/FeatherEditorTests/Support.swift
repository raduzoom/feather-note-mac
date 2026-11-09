import Foundation

enum Corpus {
    static var directory: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: "corpus") }

    static func all() -> [(name: String, text: String)] {
        let files = try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.map { ($0.lastPathComponent, String(decoding: try! Data(contentsOf: $0), as: UTF8.self)) }
    }
}

/// Deterministic RNG so random edit sequences repeat.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Prints a timing line to stderr, unbuffered, so it survives a run that is stopped.
func perf(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

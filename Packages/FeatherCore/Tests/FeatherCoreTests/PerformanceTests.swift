import Foundation
import Testing
@testable import FeatherCore

/// Deterministic RNG so the corpus is the same on every run.
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

private func word(_ i: Int) -> String {
    // 2,000 distinct pronounceable words.
    let a = ["ka", "lo", "mi", "ne", "ru", "sa", "te", "vi", "zo", "pa"]
    let b = ["ber", "cal", "dun", "fen", "gor", "hal", "jin", "kel", "lum", "mor", "nix", "pol", "quen", "ras", "sol", "tam", "ul", "ven", "wex", "yor"]
    let c = ["a", "e", "i", "o", "u", "an", "en", "is", "os", "um"]
    return a[i % 10] + b[(i / 10) % 20] + c[(i / 200) % 10]
}

private func median(_ xs: [Duration]) -> Duration { xs.sorted()[xs.count / 2] }

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

@Test(.timeLimit(.minutes(5))) func searchUnder50msOn10kNotes() async throws {
    let lib = try TestLibrary.open()
    var rng = SplitMix64(state: 42)
    var notebooks: [ULID] = []
    for i in 0..<20 { notebooks.append(try await lib.createNotebook(name: "Notebook \(i)", parentID: nil).id) }
    var tags: [ULID] = []
    for i in 0..<30 { tags.append(try await lib.createTag(name: "tag\(i)").id) }

    var drafts: [NoteDraft] = []
    for _ in 0..<10_000 {
        let title = (0..<Int.random(in: 3...8, using: &rng)).map { _ in word(Int.random(in: 0..<2000, using: &rng)) }.joined(separator: " ")
        let body = (0..<300).map { _ in word(Int.random(in: 0..<2000, using: &rng)) }.joined(separator: " ")
        let tagCount = Int.random(in: 0...3, using: &rng)
        let noteTags = Set((0..<tagCount).map { _ in tags[Int.random(in: 0..<30, using: &rng)] })
        drafts.append(NoteDraft(title: title, body: body, notebookID: notebooks[Int.random(in: 0..<20, using: &rng)], tagIDs: noteTags))
    }
    try await lib.createInOneTransaction(drafts)

    let clock = ContinuousClock()
    var queries: [(String, ULID?, Set<ULID>)] = []
    for i in 0..<8 { queries.append((word(i * 97), nil, [])) }
    for i in 0..<6 { queries.append((word(i * 31) + " " + word(i * 53 + 7), nil, [])) }
    for i in 0..<5 { queries.append((String(word(i * 211).prefix(3)), nil, [])) }
    queries.append((word(500), notebooks[3], [tags[5]]))

    var times: [Duration] = []
    for (q, nb, t) in queries {
        times.append(try await clock.measure { _ = try await lib.search(q, notebookID: nb, tagIDs: t) })
    }
    let listTime = try await clock.measure { _ = try await lib.notes(in: .all) }
    let countsTime = try await clock.measure { _ = try await lib.counts() }
    print("PERF search median \(seconds(median(times)) * 1000) ms, max \(seconds(times.max()!) * 1000) ms; list all \(seconds(listTime) * 1000) ms")
    #expect(median(times) < .milliseconds(50))
    #expect(times.max()! < .milliseconds(150))
    // The gate is the release build (the app ships release): run with `swift test -c release`.
    // Debug builds are several times slower at mapping rows, so they only catch large regressions.
    #if DEBUG
    let listLimit = Duration.milliseconds(1000)
    #else
    let listLimit = Duration.milliseconds(50)
    #endif
    #expect(listTime < listLimit)
    print("PERF counts \(seconds(countsTime) * 1000) ms")
    #if !DEBUG
    #expect(countsTime < .milliseconds(20))
    #endif
}

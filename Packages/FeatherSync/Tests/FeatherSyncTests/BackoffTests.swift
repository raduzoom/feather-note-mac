import Testing
@testable import FeatherSync

@Suite struct BackoffTests {
    @Test func doublesToFiveMinutes() {
        var b = Backoff()
        let delays = (0..<10).map { _ in b.next(random: 0.5) }
        #expect(delays == [2, 4, 8, 16, 32, 64, 128, 256, 300, 300].map { Duration.seconds($0) })
    }

    @Test func jitterIsTwentyPercent() {
        var low = Backoff(), high = Backoff()
        #expect(low.next(random: 0) == .milliseconds(1600))
        #expect(high.next(random: 1) == .milliseconds(2400))
    }

    @Test func resetStartsOver() {
        var b = Backoff()
        _ = b.next(random: 0.5)
        _ = b.next(random: 0.5)
        b.reset()
        #expect(b.next(random: 0.5) == .seconds(2))
    }
}

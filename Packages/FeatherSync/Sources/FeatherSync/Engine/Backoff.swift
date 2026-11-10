/// Retry delays after a failed sync: 2 s doubling to 5 min, ±20% jitter (sync-protocol.md "Errors and retries").
public struct Backoff: Sendable {
    private var attempt = 0
    public init() {}

    /// `random` in 0...1 picks the jitter.
    public mutating func next(random: Double) -> Duration {
        let base = min(300.0, 2.0 * Double(1 << min(attempt, 20)))
        attempt += 1
        let ms = (base * (0.8 + 0.4 * random) * 1000).rounded()
        return .milliseconds(Int64(ms))
    }

    public mutating func reset() { attempt = 0 }
}

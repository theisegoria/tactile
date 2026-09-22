// A pure token-bucket rate limiter. Time is injected so it is deterministic
// under test. Used to cap output report 0x31 so a caller bug cannot flood the
// Bluetooth link.

public struct RateLimiter: Sendable {
    public let minimumInterval: UInt64  // nanoseconds
    public let burst: Int
    private var tokens: Double
    private var last: UInt64?

    /// - Parameters:
    ///   - maxPerSecond: sustained rate.
    ///   - burst: number of reports allowed back-to-back.
    public init(maxPerSecond: Double, burst: Int = 2) {
        minimumInterval = UInt64(1_000_000_000 / max(maxPerSecond, 0.001))
        self.burst = max(burst, 1)
        tokens = Double(self.burst)
    }

    /// Returns true and consumes a token if a send is allowed at `now` (ns).
    public mutating func tryAcquire(now: UInt64) -> Bool {
        if let l = last, now > l {
            tokens = min(Double(burst), tokens + Double(now - l) / Double(minimumInterval))
        }
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// Nanoseconds until the next token is available at `now` (0 if available).
    public func delayUntilAvailable(now: UInt64) -> UInt64 {
        guard let l = last else { return 0 }
        let refill = now > l ? Double(now - l) / Double(minimumInterval) : 0
        let t = min(Double(burst), tokens + refill)
        if t >= 1 { return 0 }
        return UInt64((1 - t) * Double(minimumInterval))
    }
}

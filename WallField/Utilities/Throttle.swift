import Foundation

/// Rate limiter used to keep UI publication and haptics well below sensor rate.
///
/// Sensor processing runs at roughly 50 Hz; the readouts on the scan screen are
/// republished at 10 Hz, and haptics are limited far more aggressively still.
/// Both limits exist to avoid burning battery and generating heat for updates a
/// person cannot perceive.
struct RateLimiter {
    /// Minimum seconds between permitted events.
    let minimumInterval: TimeInterval
    private var lastFired: TimeInterval?

    init(hz: Double) {
        precondition(hz > 0, "rate must be positive")
        self.minimumInterval = 1.0 / hz
    }

    init(minimumInterval: TimeInterval) {
        precondition(minimumInterval >= 0, "interval must not be negative")
        self.minimumInterval = minimumInterval
    }

    /// Returns `true` at most once per `minimumInterval` on the supplied clock.
    mutating func allow(at now: TimeInterval) -> Bool {
        guard let last = lastFired else {
            lastFired = now
            return true
        }
        // A backwards jump (only possible with an injected clock in tests) is
        // treated as a reset rather than blocking events forever.
        if now < last {
            lastFired = now
            return true
        }
        guard now - last >= minimumInterval else { return false }
        lastFired = now
        return true
    }

    mutating func reset() {
        lastFired = nil
    }
}

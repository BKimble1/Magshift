import Foundation

/// The single time basis the whole app uses to correlate sensor and AR data.
///
/// Core Motion timestamps and ARKit timestamps are both expressed as seconds
/// since an unspecified reference, and the app must not assume the two share an
/// epoch. Instead every callback records `ProcessInfo.processInfo.systemUptime`
/// at the moment it fires, and all matching happens in that one basis.
///
/// `systemUptime` is monotonic while the device is awake and is not affected by
/// wall-clock changes, which is exactly what is needed here. It does not advance
/// while the device is asleep -- irrelevant for an in-progress scan, which
/// cannot survive the device sleeping.
///
/// See `Docs/ARCHITECTURE.md` -> "Time basis" for the full rationale.
protocol MonotonicClock: Sendable {
    /// Seconds on the shared monotonic basis.
    var now: TimeInterval { get }
}

/// Production clock backed by `ProcessInfo.processInfo.systemUptime`.
struct SystemMonotonicClock: MonotonicClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Deterministic clock for tests and simulated data. Time only moves when the
/// test moves it.
///
/// `@unchecked Sendable` is justified: the only mutable state is a single
/// `TimeInterval`, and every read and write of it goes through `lock`. It cannot
/// be an actor because `MonotonicClock.now` is a synchronous requirement, called
/// from sensor callbacks that cannot await.
final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(start: TimeInterval = 0) {
        self.value = start
    }

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }

    func set(_ seconds: TimeInterval) {
        lock.lock()
        value = seconds
        lock.unlock()
    }
}

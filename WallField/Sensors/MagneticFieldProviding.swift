import Foundation

/// Source of magnetic-field samples.
///
/// Main-actor isolated on purpose. Sample arithmetic is O(1) per sample at
/// roughly 50 Hz, which is negligible on the main actor, and confining it there
/// removes an entire class of data race between the Core Motion callback, the
/// ARKit callback and SwiftUI state. Work that is *not* O(1) -- persistence,
/// CSV and JSON generation -- is explicitly moved off the main actor where it
/// happens. See `Docs/ARCHITECTURE.md` -> "Concurrency".
@MainActor
protocol MagneticFieldProviding: AnyObject {
    /// What the hardware and Core Motion can currently do.
    var availability: MagneticFieldAvailability { get }

    /// Whether updates are currently running.
    var isRunning: Bool { get }

    /// Requested sampling rate in Hz for the most recent `start`.
    var requestedSampleRate: Double { get }

    /// Health of the delivered stream, recomputed continuously.
    var timingHealth: SampleTimingHealth { get }

    /// Starts updates and returns the sample stream.
    ///
    /// Calling `start` while already running stops the previous stream first, so
    /// there is never more than one active Core Motion subscription.
    func start(preferredSampleRate: Double) -> AsyncStream<MagneticFieldSample>

    /// Stops updates and finishes the stream. Safe to call when not running.
    func stop()
}

extension MagneticFieldProviding {
    /// The rate the app asks for. Core Motion is free to deliver something else,
    /// which is exactly why every sample carries its own measured interval.
    static var defaultSampleRate: Double { 50 }

    func start() -> AsyncStream<MagneticFieldSample> {
        start(preferredSampleRate: Self.defaultSampleRate)
    }
}

/// Rolling measurement of how the sample stream is actually behaving.
struct SampleRateTracker {
    private var intervals: BoundedBuffer<TimeInterval>
    private var lastTimestamp: TimeInterval?

    /// Two seconds at 50 Hz.
    init(capacity: Int = 100) {
        intervals = BoundedBuffer(capacity: capacity)
    }

    private(set) var health: SampleTimingHealth = .unknown

    /// Records a delivered sample and returns the interval since the previous one.
    @discardableResult
    mutating func record(timestamp: TimeInterval, reportedInterval: TimeInterval?) -> TimeInterval {
        let measured: TimeInterval
        if let reportedInterval, reportedInterval > 0, reportedInterval.isFinite {
            measured = reportedInterval
        } else if let lastTimestamp, timestamp > lastTimestamp {
            measured = timestamp - lastTimestamp
        } else {
            measured = 0
        }
        lastTimestamp = timestamp
        if measured > 0 {
            intervals.append(measured)
            recomputeHealth()
        }
        return measured
    }

    private mutating func recomputeHealth() {
        let values = intervals.elements
        guard !values.isEmpty else {
            health = .unknown
            return
        }
        let mean = values.reduce(0, +) / Double(values.count)
        health = SampleTimingHealth(
            measuredRate: mean > 0 ? 1 / mean : 0,
            meanInterval: mean,
            maximumGap: values.max() ?? 0,
            sampleCount: values.count
        )
    }

    mutating func reset() {
        intervals.removeAll()
        lastTimestamp = nil
        health = .unknown
    }
}

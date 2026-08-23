import Foundation

/// Magnetic-field source backed by `SimulatedEnvironment`.
///
/// # Why it emits in bursts
///
/// Sample timestamps advance on a regular grid of `1 / rate` seconds, anchored
/// to the real monotonic clock. When the timer that drives it fires late -- as
/// it will on a Simulator running a UI test -- the service emits every sample
/// the grid says is due rather than skipping them.
///
/// This mirrors real hardware: Core Motion buffers and delivers a burst when the
/// main thread stalls, it does not silently drop samples. It also means timing
/// health, interval measurement and sensor-to-pose matching exercise their real
/// code paths against a stream that does not spuriously look stalled, so a UI
/// test does not fail because the Simulator was busy.
///
/// After a very long stall the grid is resynchronised to now rather than
/// emitting an unbounded catch-up burst.
@MainActor
final class SimulatedMagneticFieldService: MagneticFieldProviding {
    private let environment: SimulatedEnvironment
    private let clock: any MonotonicClock
    private var continuation: AsyncStream<MagneticFieldSample>.Continuation?
    private var emitTask: Task<Void, Never>?
    private var rateTracker = SampleRateTracker()
    private var nextTimestamp: TimeInterval?
    private var period: TimeInterval = 0.02

    /// The most samples one tick may emit while catching up. Beyond this the
    /// grid is resynchronised instead.
    private static let maximumBurst = 25

    private(set) var isRunning = false
    private(set) var requestedSampleRate: Double = 50

    /// Reports the same shape of availability a healthy device would, so the
    /// Simulator exercises the normal path rather than a permission-error path.
    private(set) var availability = MagneticFieldAvailability(
        isDeviceMotionAvailable: true,
        isMagnetometerAvailable: true,
        isAttitudeReferenceFrameAvailable: true,
        activeSource: .simulated,
        failureDescription: nil
    )

    var timingHealth: SampleTimingHealth { rateTracker.health }

    init(environment: SimulatedEnvironment, clock: any MonotonicClock = SystemMonotonicClock()) {
        self.environment = environment
        self.clock = clock
    }

    func start(preferredSampleRate: Double) -> AsyncStream<MagneticFieldSample> {
        stop()
        let rate = max(1, min(preferredSampleRate, 100))
        requestedSampleRate = rate
        rateTracker.reset()
        period = 1 / rate
        nextTimestamp = nil
        environment.start()

        let (stream, continuation) = AsyncStream<MagneticFieldSample>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.continuation = continuation
        isRunning = true

        let periodNanoseconds = UInt64((1 / rate) * 1_000_000_000)
        emitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.emitSample()
                try? await Task.sleep(nanoseconds: periodNanoseconds)
            }
        }

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
        return stream
    }

    func stop() {
        guard isRunning || continuation != nil else { return }
        emitTask?.cancel()
        emitTask = nil
        isRunning = false
        let finishing = continuation
        continuation = nil
        finishing?.finish()
    }

    private func emitSample() {
        guard let continuation else { return }
        let now = clock.now

        guard var next = nextTimestamp else {
            nextTimestamp = now + period
            emit(at: now, interval: 0, to: continuation)
            return
        }

        var emitted = 0
        while next <= now, emitted < Self.maximumBurst {
            emit(at: next, interval: period, to: continuation)
            next += period
            emitted += 1
        }
        if emitted >= Self.maximumBurst {
            // A long stall. Resynchronise rather than emitting an unbounded
            // backlog, and let the timing health reflect the gap honestly.
            next = now + period
        }
        nextTimestamp = next
    }

    private func emit(
        at timestamp: TimeInterval,
        interval: TimeInterval,
        to continuation: AsyncStream<MagneticFieldSample>.Continuation
    ) {
        let magnitude = environment.sampleMagnitude()
        let vector = environment.vector(forMagnitude: magnitude)
        let sample = MagneticFieldSample(
            timestamp: timestamp,
            x: vector.x,
            y: vector.y,
            z: vector.z,
            accuracy: .high,
            interval: interval,
            source: .simulated,
            motion: environment.motionEnergy
        )
        rateTracker.record(timestamp: timestamp, reportedInterval: interval)
        continuation.yield(sample)
    }
}

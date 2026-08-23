import Foundation

/// Magnetic-field source backed by `SimulatedEnvironment`.
///
/// Emits at the requested rate on the *real* monotonic clock, so timing health,
/// interval measurement and sensor/pose matching all exercise their production
/// code paths rather than being short-circuited. The field values themselves are
/// deterministic.
@MainActor
final class SimulatedMagneticFieldService: MagneticFieldProviding {
    private let environment: SimulatedEnvironment
    private let clock: any MonotonicClock
    private var continuation: AsyncStream<MagneticFieldSample>.Continuation?
    private var emitTask: Task<Void, Never>?
    private var rateTracker = SampleRateTracker()
    private var lastTimestamp: TimeInterval?

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
        lastTimestamp = nil
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
        let interval = lastTimestamp.map { max(0, now - $0) } ?? 0
        lastTimestamp = now

        let magnitude = environment.sampleMagnitude()
        let vector = environment.vector(forMagnitude: magnitude)
        let sample = MagneticFieldSample(
            timestamp: now,
            x: vector.x,
            y: vector.y,
            z: vector.z,
            accuracy: .high,
            interval: interval,
            source: .simulated,
            motion: environment.motionEnergy
        )
        rateTracker.record(timestamp: now, reportedInterval: interval)
        continuation.yield(sample)
    }
}

/// Replays a fixed script of samples. Used by unit tests and previews where even
/// the simulated environment's timing is more machinery than the test needs.
@MainActor
final class ScriptedMagneticFieldService: MagneticFieldProviding {
    private let script: [MagneticFieldSample]
    private var continuation: AsyncStream<MagneticFieldSample>.Continuation?
    private var task: Task<Void, Never>?

    private(set) var isRunning = false
    private(set) var requestedSampleRate: Double = 50
    private(set) var availability = MagneticFieldAvailability(
        isDeviceMotionAvailable: true,
        isMagnetometerAvailable: true,
        isAttitudeReferenceFrameAvailable: true,
        activeSource: .simulated,
        failureDescription: nil
    )
    var timingHealth: SampleTimingHealth {
        SampleTimingHealth(measuredRate: 50, meanInterval: 0.02, maximumGap: 0.02, sampleCount: script.count)
    }

    init(script: [MagneticFieldSample]) {
        self.script = script
    }

    func start(preferredSampleRate: Double) -> AsyncStream<MagneticFieldSample> {
        stop()
        requestedSampleRate = preferredSampleRate
        let (stream, continuation) = AsyncStream<MagneticFieldSample>.makeStream()
        self.continuation = continuation
        isRunning = true
        let samples = script
        task = Task { @MainActor in
            for sample in samples {
                if Task.isCancelled { break }
                continuation.yield(sample)
                await Task.yield()
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        continuation?.finish()
        continuation = nil
    }
}

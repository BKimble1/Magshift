import CoreMotion
import Foundation

/// The production magnetic-field source.
///
/// # Which Core Motion API and why
///
/// `CMDeviceMotion.magneticField` is preferred over raw magnetometer data.
/// Apple describes it as the total magnetic field around the device with the
/// device's own bias removed, and it carries a calibration-accuracy estimate --
/// both of which this app depends on. Raw `magnetometerData` includes hard- and
/// soft-iron bias from the phone itself and reports no accuracy, so it is
/// offered only as a clearly labelled diagnostic fallback and can never anchor a
/// marker (`MagneticFieldSource.isAcceptableForDetection`).
///
/// The attitude reference frame is *checked* rather than assumed:
/// `.xArbitraryCorrectedZVertical` is requested when available, because it needs
/// no true-north fix and therefore starts producing calibrated data quickly, and
/// the code falls back through the frames the device does report.
///
/// # Time basis
///
/// Every sample is stamped with `ProcessInfo.processInfo.systemUptime` captured
/// *inside the callback*, which is the same basis the AR pose buffer uses. The
/// delivered interval is measured from Core Motion's own timestamps, which are
/// higher resolution than the callback scheduling. The offset between the two
/// clocks is measured and exposed in Diagnostics so the assumption that they
/// share an epoch can be verified on a real device rather than believed.
///
/// # Lifecycle
///
/// Exactly one `CMMotionManager` exists for the lifetime of the service. `start`
/// is idempotent: it stops any previous stream first, so there is never more
/// than one active subscription or more than one live continuation.
@MainActor
final class CoreMotionMagneticFieldService: MagneticFieldProviding {

    /// `nonisolated(unsafe)` so `deinit`, which is not main-actor isolated, can
    /// stop updates as a last resort. `CMMotionManager`'s stop methods are safe
    /// to call from any thread, and once `deinit` runs no other reference to
    /// this service exists, so there is no concurrent access to guard.
    private nonisolated(unsafe) let motionManager = CMMotionManager()

    private let clock: any MonotonicClock
    private let handlerQueue: OperationQueue
    private var continuation: AsyncStream<MagneticFieldSample>.Continuation?
    private var rateTracker = SampleRateTracker()
    private let intervalTracker = IntervalTracker()

    private(set) var availability: MagneticFieldAvailability
    private(set) var isRunning = false
    private(set) var requestedSampleRate: Double = 50
    private(set) var activeReferenceFrame: CMAttitudeReferenceFrame?

    var timingHealth: SampleTimingHealth { rateTracker.health }

    /// Mean observed `systemUptime - CMDeviceMotion.timestamp`, once enough
    /// samples exist. Near zero means the two clocks share an epoch. Surfaced in
    /// Diagnostics; nothing in the pipeline depends on it.
    private(set) var observedCoreMotionClockOffset: TimeInterval?
    private var offsetSampleCount = 0
    private var offsetAccumulator: TimeInterval = 0

    /// Incremented by every `start`. A stream's termination handler carries the
    /// generation it belonged to, so a handler that fires late cannot stop a
    /// stream that a later `start` has already put in its place.
    private var generation = 0

    init(clock: any MonotonicClock = SystemMonotonicClock()) {
        self.clock = clock
        let queue = OperationQueue()
        queue.name = "com.idlery.wallfield.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        self.handlerQueue = queue
        self.availability = CoreMotionMagneticFieldService.readAvailability(motionManager)
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopMagnetometerUpdates()
    }

    // MARK: - MagneticFieldProviding

    func start(preferredSampleRate: Double) -> AsyncStream<MagneticFieldSample> {
        stop()
        generation &+= 1
        let generation = self.generation

        let rate = max(1, min(preferredSampleRate, 100))
        requestedSampleRate = rate
        rateTracker.reset()
        intervalTracker.reset()
        offsetAccumulator = 0
        offsetSampleCount = 0
        observedCoreMotionClockOffset = nil
        availability = CoreMotionMagneticFieldService.readAvailability(motionManager)

        let (stream, continuation) = AsyncStream<MagneticFieldSample>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.continuation = continuation

        if availability.supportsCalibratedField, let frame = Self.preferredReferenceFrame() {
            startDeviceMotion(frame: frame, rate: rate, continuation: continuation)
        } else if availability.isMagnetometerAvailable {
            startRawMagnetometer(rate: rate, continuation: continuation)
        } else {
            Log.sensors.error("No magnetic-field source available on this device.")
            availability = .unavailable
            continuation.finish()
            self.continuation = nil
            return stream
        }

        isRunning = true
        continuation.onTermination = { [weak self] _ in
            // Termination can arrive on any thread when the consumer's task is
            // cancelled, so hop back to the main actor before touching state.
            // That hop means the handler runs *after* whatever ran it, which may
            // well be a `start` that has already installed a newer stream --
            // hence the generation check rather than a bare `stop()`.
            Task { @MainActor [weak self] in
                self?.stopIfCurrent(generation: generation)
            }
        }
        return stream
    }

    /// Stops only if `generation` is still the live one.
    private func stopIfCurrent(generation: Int) {
        guard generation == self.generation else { return }
        stop()
    }

    func stop() {
        guard isRunning || continuation != nil else { return }
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopMagnetometerUpdates()
        isRunning = false
        activeReferenceFrame = nil
        let finishing = continuation
        continuation = nil
        finishing?.finish()
        Log.sensors.debug("Magnetic field updates stopped.")
    }

    // MARK: - Starting

    private func startDeviceMotion(
        frame: CMAttitudeReferenceFrame,
        rate: Double,
        continuation: AsyncStream<MagneticFieldSample>.Continuation
    ) {
        motionManager.deviceMotionUpdateInterval = 1 / rate
        activeReferenceFrame = frame
        availability.activeSource = .calibratedDeviceMotion

        let clock = self.clock
        let tracker = self.intervalTracker

        motionManager.startDeviceMotionUpdates(using: frame, to: handlerQueue) { motion, error in
            if let error {
                Task { @MainActor in
                    Log.sensors.error("Device motion error: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            guard let motion else { return }
            let monotonic = clock.now
            let field = motion.magneticField
            let interval = tracker.interval(forDeviceTimestamp: motion.timestamp)
            let acceleration = motion.userAcceleration
            let rotation = motion.rotationRate
            let sample = MagneticFieldSample(
                timestamp: monotonic,
                x: field.field.x,
                y: field.field.y,
                z: field.field.z,
                accuracy: MagneticFieldAccuracy(field.accuracy),
                interval: interval,
                source: .calibratedDeviceMotion,
                motion: MotionEnergy(
                    userAcceleration: (acceleration.x * acceleration.x
                        + acceleration.y * acceleration.y
                        + acceleration.z * acceleration.z).squareRoot(),
                    rotationRate: (rotation.x * rotation.x
                        + rotation.y * rotation.y
                        + rotation.z * rotation.z).squareRoot()
                )
            )
            let clockDelta = monotonic - motion.timestamp
            continuation.yield(sample)
            Task { @MainActor [weak self] in
                self?.noteDelivered(sample, clockDelta: clockDelta)
            }
        }
        Log.sensors.debug("Calibrated device-motion updates started.")
    }

    private func startRawMagnetometer(
        rate: Double,
        continuation: AsyncStream<MagneticFieldSample>.Continuation
    ) {
        motionManager.magnetometerUpdateInterval = 1 / rate
        availability.activeSource = .rawMagnetometer

        let clock = self.clock
        let tracker = self.intervalTracker

        motionManager.startMagnetometerUpdates(to: handlerQueue) { data, error in
            if let error {
                Task { @MainActor in
                    Log.sensors.error("Magnetometer error: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            guard let data else { return }
            let monotonic = clock.now
            let interval = tracker.interval(forDeviceTimestamp: data.timestamp)
            let sample = MagneticFieldSample(
                timestamp: monotonic,
                x: data.magneticField.x,
                y: data.magneticField.y,
                z: data.magneticField.z,
                // Raw data reports no calibration accuracy at all. Reporting it
                // as `.uncalibrated` is the honest mapping, and it is what stops
                // this source ever reaching the placement path.
                accuracy: .uncalibrated,
                interval: interval,
                source: .rawMagnetometer,
                motion: nil
            )
            let clockDelta = monotonic - data.timestamp
            continuation.yield(sample)
            Task { @MainActor [weak self] in
                self?.noteDelivered(sample, clockDelta: clockDelta)
            }
        }
        Log.sensors.notice("Falling back to raw magnetometer: reduced-quality diagnostics only.")
    }

    private func noteDelivered(_ sample: MagneticFieldSample, clockDelta: TimeInterval) {
        rateTracker.record(timestamp: sample.timestamp, reportedInterval: sample.interval)
        guard clockDelta.isFinite else { return }
        offsetAccumulator += clockDelta
        offsetSampleCount += 1
        if offsetSampleCount >= 25 {
            observedCoreMotionClockOffset = offsetAccumulator / Double(offsetSampleCount)
        }
    }

    // MARK: - Capability probing

    /// Picks the best available attitude reference frame.
    ///
    /// `.xArbitraryCorrectedZVertical` is preferred: it is corrected by the
    /// magnetometer but does not wait for a true-north fix, so calibrated field
    /// data starts flowing quickly indoors. Availability is queried, never
    /// assumed.
    static func preferredReferenceFrame() -> CMAttitudeReferenceFrame? {
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        let ordered: [CMAttitudeReferenceFrame] = [
            .xArbitraryCorrectedZVertical,
            .xMagneticNorthZVertical,
            .xTrueNorthZVertical,
            .xArbitraryZVertical,
        ]
        return ordered.first { available.contains($0) }
    }

    static func readAvailability(_ manager: CMMotionManager) -> MagneticFieldAvailability {
        let deviceMotion = manager.isDeviceMotionAvailable
        let magnetometer = manager.isMagnetometerAvailable
        let frame = preferredReferenceFrame()
        var failure: String?
        if !deviceMotion && !magnetometer {
            failure = "This device does not report magnetic-field data."
        } else if !deviceMotion || frame == nil {
            failure = "Calibrated magnetic data is unavailable; only reduced-quality diagnostics are possible."
        }
        return MagneticFieldAvailability(
            isDeviceMotionAvailable: deviceMotion,
            isMagnetometerAvailable: magnetometer,
            isAttitudeReferenceFrameAvailable: frame != nil,
            activeSource: nil,
            failureDescription: failure
        )
    }
}

/// Measures the delivered interval between Core Motion callbacks.
///
/// `@unchecked Sendable` is justified: the only mutable state is one
/// `TimeInterval?` and every read and write is inside `lock`. It cannot be an
/// actor because it is called synchronously from a Core Motion handler.
private final class IntervalTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: TimeInterval?

    /// Returns the interval since the previous callback, or 0 for the first.
    func interval(forDeviceTimestamp timestamp: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        defer { previous = timestamp }
        guard let previous, timestamp > previous else { return 0 }
        return timestamp - previous
    }

    func reset() {
        lock.lock()
        previous = nil
        lock.unlock()
    }
}

extension MagneticFieldAccuracy {
    init(_ accuracy: CMMagneticFieldCalibrationAccuracy) {
        switch accuracy {
        case .uncalibrated: self = .uncalibrated
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        @unknown default: self = .uncalibrated
        }
    }
}

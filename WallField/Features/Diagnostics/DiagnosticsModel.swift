import Foundation
import Observation

/// One row of a diagnostic recording.
struct DiagnosticSample: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var timestamp: TimeInterval
    var elapsed: TimeInterval
    var x: Double
    var y: Double
    var z: Double
    var magnitude: Double
    var smoothedMagnitude: Double
    var baseline: Double
    var delta: Double
    var robustZScore: Double
    var sigma: Double
    var gradient: Double
    var persistence: Int
    var detectorState: DetectorState
    var accuracy: MagneticFieldAccuracy
    var interval: TimeInterval
    var source: MagneticFieldSource
    var userAcceleration: Double?
    var rotationRate: Double?
    var trackingState: TrackingQuality?
    var raycastDistance: Double?
}

/// A labelled diagnostic recording.
struct DiagnosticRun: Codable, Sendable, Hashable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = DiagnosticRun.currentSchemaVersion
    var id: UUID
    var label: String
    var notes: String
    var startedAt: Date
    var endedAt: Date
    var appVersion: String
    var algorithmVersion: String
    var device: DeviceMetadata
    var isSimulated: Bool
    var configuration: DetectorConfiguration
    var calibration: CalibrationSummary?
    var requestedSampleRate: Double
    var measuredSampleRate: Double
    /// Mean of `systemUptime - CMDeviceMotion.timestamp`, when it could be
    /// measured. Near zero means the two clocks share an epoch.
    var coreMotionClockOffset: TimeInterval?
    var samples: [DiagnosticSample]

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

/// Drives the sensor diagnostics and validation lab.
///
/// # Why this is a first-class feature
///
/// The product's entire premise -- that an iPhone magnetometer can register
/// something useful through a wall surface -- is a *hypothesis about hardware*.
/// It cannot be settled by reasoning or by unit tests; it has to be measured
/// against known ground truth on real devices. This screen is the instrument
/// that produces that evidence, and `Docs/VALIDATION_PROTOCOL.md` is the
/// experiment plan it feeds.
@MainActor
@Observable
final class DiagnosticsModel {

    // MARK: - Dependencies

    private let fieldService: any MagneticFieldProviding

    /// Builds a spatial provider, or returns `nil` when this device has no AR to
    /// offer. Called at most once, and only when AR is actually switched on.
    ///
    /// A factory rather than an instance because this screen's job is the
    /// magnetometer: AR is an optional extra that most diagnostic runs never
    /// touch. Holding an instance meant opening Sensor diagnostics built the
    /// whole ARKit and RealityKit stack before a single number was on screen.
    private let spatialProviderFactory: @MainActor () -> (any ARSpatialProviding)?
    private var spatialProvider: (any ARSpatialProviding)?
    private let capabilities: DeviceCapabilities
    private let configuration: DetectorConfiguration
    private let clock: any MonotonicClock
    let isSimulated: Bool

    // MARK: - Engines

    private var detector: OnlineAnomalyDetector
    private var calibrationEngine: CalibrationEngine

    // MARK: - Observable state

    private(set) var isStreaming = false
    private(set) var isRecording = false
    private(set) var isCalibrating = false
    private(set) var latest: DiagnosticSample?
    private(set) var calibration: CalibrationSummary?
    private(set) var calibrationProgress: Double = 0
    private(set) var calibrationRejection: CalibrationRejection?
    private(set) var chartPoints: [ChartPoint] = []
    private(set) var recordedCount = 0
    private(set) var completedRun: DiagnosticRun?
    private(set) var isARActive = false
    private(set) var exportError: String?

    var runLabel = ""
    var runNotes = ""

    var availability: MagneticFieldAvailability { fieldService.availability }
    var timing: SampleTimingHealth { fieldService.timingHealth }
    var requestedSampleRate: Double { fieldService.requestedSampleRate }
    var trackingQuality: TrackingQuality? { isARActive ? spatialProvider?.trackingQuality : nil }
    var raycastDistance: Double? { spatialProvider?.currentHit?.distanceFromCamera }
    var targetedWallID: UUID? { isARActive ? spatialProvider?.targetedWallID : nil }
    var isWallLocked: Bool { spatialProvider?.lockedWall != nil }
    var arSessionController: ARSessionController? { spatialProvider as? ARSessionController }
    /// Whether the AR section should be offered at all.
    let supportsAR: Bool
    var coreMotionClockOffset: TimeInterval? {
        (fieldService as? CoreMotionMagneticFieldService)?.observedCoreMotionClockOffset
    }

    /// One point on the scrolling chart.
    struct ChartPoint: Identifiable, Sendable, Hashable {
        var id: Int
        var elapsed: TimeInterval
        var magnitude: Double
        var baseline: Double
    }

    /// The chart is published at 5 Hz and holds 60 points, so it shows the last
    /// twelve seconds. Drawing it at sensor rate would redraw a path 50 times a
    /// second for no readable benefit.
    private static let chartCapacity = 60

    // MARK: - Private state

    private var sampleTask: Task<Void, Never>?
    private var recorded: [DiagnosticSample] = []
    private var startTimestamp: TimeInterval?
    private var recordingStartedAt: Date?
    private var recordingStartTimestamp: TimeInterval?
    private var chartCounter = 0
    private var chartLimiter = RateLimiter(hz: 5)
    private var readoutLimiter = RateLimiter(hz: Theme.readoutUpdatesPerSecond)

    /// Hard cap on a recording: 20 minutes at 50 Hz. A recording that hits this
    /// stops rather than growing without bound, and says so.
    static let maximumRecordedSamples = 60_000
    private(set) var didHitRecordingLimit = false

    // MARK: - Init

    init(
        fieldService: any MagneticFieldProviding,
        supportsAR: Bool,
        spatialProviderFactory: @escaping @MainActor () -> (any ARSpatialProviding)?,
        capabilities: DeviceCapabilities,
        configuration: DetectorConfiguration,
        isSimulated: Bool,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) {
        self.fieldService = fieldService
        self.supportsAR = supportsAR
        self.spatialProviderFactory = spatialProviderFactory
        self.capabilities = capabilities
        self.configuration = configuration
        self.isSimulated = isSimulated
        self.clock = clock
        self.detector = OnlineAnomalyDetector(configuration: configuration)
        self.calibrationEngine = CalibrationEngine(configuration: configuration)
    }

    // MARK: - Streaming

    func start() {
        guard !isStreaming else { return }
        startTimestamp = clock.now
        let stream = HardwarePhaseRecorder.attempting(.startingMagnetometer) {
            fieldService.start(preferredSampleRate: 50)
        }
        isStreaming = true
        sampleTask = Task { @MainActor [weak self] in
            for await sample in stream {
                guard let self else { break }
                self.process(sample)
            }
        }
    }

    func stop() {
        sampleTask?.cancel()
        sampleTask = nil
        fieldService.stop()
        isStreaming = false
        if isRecording { finishRecording() }
        setARActive(false)
    }

    // MARK: - Calibration

    func startCalibration() {
        calibrationEngine.reset()
        calibrationProgress = 0
        calibrationRejection = nil
        detector.invalidateCalibration()
        calibration = nil
        isCalibrating = true
    }

    func cancelCalibration() {
        calibrationEngine.reset()
        isCalibrating = false
        calibrationProgress = 0
    }

    // MARK: - Recording

    func startRecording() {
        guard isStreaming else { return }
        recorded.removeAll(keepingCapacity: true)
        recordedCount = 0
        didHitRecordingLimit = false
        recordingStartedAt = Date()
        recordingStartTimestamp = clock.now
        completedRun = nil
        readoutLimiter.reset()
        isRecording = true
    }

    @discardableResult
    func finishRecording() -> DiagnosticRun? {
        guard isRecording else { return nil }
        isRecording = false
        recordedCount = recorded.count
        let run = DiagnosticRun(
            id: UUID(),
            label: runLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Diagnostic run"
                : runLabel,
            notes: runNotes,
            startedAt: recordingStartedAt ?? Date(),
            endedAt: Date(),
            appVersion: Branding.versionDisplayString,
            algorithmVersion: AlgorithmVersion.current,
            device: DeviceMetadata.current(capabilities: capabilities),
            isSimulated: isSimulated,
            configuration: configuration,
            calibration: calibration,
            requestedSampleRate: fieldService.requestedSampleRate,
            measuredSampleRate: fieldService.timingHealth.measuredRate,
            coreMotionClockOffset: coreMotionClockOffset,
            samples: recorded
        )
        completedRun = run
        return run
    }

    // MARK: - AR

    func setARActive(_ active: Bool) {
        if active {
            // Built here, on the switch, rather than when the screen appeared.
            guard supportsAR else { return }
            HardwarePhaseRecorder.attempting(.startingCamera) {
                let provider = spatialProvider ?? spatialProviderFactory()
                guard let provider else { return }
                spatialProvider = provider
                provider.start()
                isARActive = true
            }
        } else {
            spatialProvider?.stop()
            isARActive = false
        }
    }

    func lockTargetedWall() {
        guard let spatialProvider, let id = spatialProvider.targetedWallID else { return }
        _ = spatialProvider.lockWall(id: id)
    }

    // MARK: - Processing

    private func process(_ sample: MagneticFieldSample) {
        if isCalibrating {
            switch calibrationEngine.ingest(sample, tracking: .normal, requireTracking: false) {
            case .collecting(let fraction, _, _):
                calibrationProgress = fraction
            case .rejected(let reason):
                calibrationRejection = reason
                calibrationProgress = 0
                isCalibrating = false
            case .completed(let summary):
                calibration = summary
                detector.adopt(calibration: summary)
                calibrationProgress = 1
                isCalibrating = false
            }
        }

        let output = detector.ingest(sample)
        let start = startTimestamp ?? sample.timestamp
        let row = DiagnosticSample(
            id: UUID(),
            timestamp: sample.timestamp,
            elapsed: max(0, sample.timestamp - (recordingStartTimestamp ?? start)),
            x: sample.x,
            y: sample.y,
            z: sample.z,
            magnitude: sample.magnitude,
            smoothedMagnitude: output.smoothedMagnitude,
            baseline: output.baseline,
            delta: output.delta,
            robustZScore: output.robustZScore,
            sigma: output.sigma,
            gradient: output.gradient,
            persistence: output.persistence,
            detectorState: output.state,
            accuracy: sample.accuracy,
            interval: sample.interval,
            source: sample.source,
            userAcceleration: sample.motion?.userAcceleration,
            rotationRate: sample.motion?.rotationRate,
            trackingState: trackingQuality,
            raycastDistance: isARActive ? raycastDistance : nil
        )
        var isFinalRow = false
        if isRecording {
            if recorded.count < Self.maximumRecordedSamples {
                recorded.append(row)
            } else if !didHitRecordingLimit {
                didHitRecordingLimit = true
                finishRecording()
                isFinalRow = true
            }
        }

        // Every sample is recorded, but the numbers on screen are republished at
        // the same rate as the scan HUD. `@Observable` invalidates observers on
        // every write, so publishing `latest` per sample would redraw the whole
        // diagnostics screen 50 times a second beside a chart that deliberately
        // redraws at 5 Hz.
        if readoutLimiter.allow(at: sample.timestamp) || isFinalRow {
            latest = row
            if isRecording { recordedCount = recorded.count }
        }

        if chartLimiter.allow(at: sample.timestamp) {
            appendChartPoint(row, start: start)
        }
    }

    private func appendChartPoint(_ row: DiagnosticSample, start: TimeInterval) {
        chartCounter += 1
        chartPoints.append(
            ChartPoint(
                id: chartCounter,
                elapsed: row.timestamp - start,
                magnitude: row.magnitude,
                baseline: row.baseline > 0 ? row.baseline : row.magnitude
            )
        )
        if chartPoints.count > Self.chartCapacity {
            chartPoints.removeFirst(chartPoints.count - Self.chartCapacity)
        }
    }
}

import Foundation
import Observation
import UIKit

/// Values republished to the scan HUD at a throttled rate.
///
/// One struct rather than a dozen observable properties, so a refresh
/// invalidates the HUD once instead of once per number.
struct LiveReadout: Sendable, Equatable {
    var magnitude: Double = 0
    var smoothedMagnitude: Double = 0
    var baseline: Double = 0
    var delta: Double = 0
    var robustZScore: Double = 0
    var sigma: Double = 0
    var gradient: Double = 0
    var detectorState: DetectorState = .uncalibrated
    var accuracy: MagneticFieldAccuracy = .uncalibrated
    var timing: SampleTimingHealth = .unknown
    var source: MagneticFieldSource = .calibratedDeviceMotion
    var wallDistance: Double?
    var cameraSpeed: Double = 0

    /// Normalised meter level: how far the reading is towards twice the
    /// detection threshold.
    func meterLevel(configuration: DetectorConfiguration) -> Double {
        let threshold = max(configuration.enterZScore, 0.001)
        return min(1, robustZScore / (threshold * 2))
    }

    /// Where the detection threshold sits on the meter. Always the midpoint by
    /// construction, because `meterLevel` normalises against twice the threshold.
    var thresholdFraction: Double { 0.5 }

    var band: AnomalyStrengthBand {
        AnomalyStrengthBand.band(forScore: min(1, robustZScore / 10))
    }
}

/// Drives one scan from preparation to a saved record.
///
/// # What lives here and what does not
///
/// This type owns *presentation state and sequencing*: which step the user is
/// on, what the HUD shows, when to start and stop hardware. It contains no
/// statistics. Calibration, detection, quality gating and clustering are all
/// separate value types it calls into, which is what keeps each of them
/// exhaustively testable without a view, a session or a device.
@MainActor
@Observable
final class ScanCoordinator {

    // MARK: - Phases

    enum Phase: Equatable {
        /// Preparation checklist, before any hardware is started.
        case preparing
        /// Looking for vertical planes; the user picks one.
        case mappingWall
        /// A wall is locked; ready to calibrate.
        case wallLocked
        /// Collecting the quiet baseline.
        case calibrating
        /// Measuring.
        case scanning
        /// Measuring suspended, hardware still running.
        case paused
        /// Finished; a draft record is ready for review.
        case finished
        /// Something stopped the scan and the user must decide what to do.
        case blocked(ARSessionProblem)
    }

    // MARK: - Dependencies

    private let fieldService: any MagneticFieldProviding
    private let spatialProvider: any ARSpatialProviding
    private let preferences: AppPreferences
    private let scanStore: any ScanStoring
    private let feedback: FeedbackController
    private let capabilities: DeviceCapabilities
    private let clock: any MonotonicClock
    let isSimulated: Bool
    let simulatedEnvironment: SimulatedEnvironment?

    /// Frozen for the whole scan: changing sensitivity mid-scan would make the
    /// stored configuration a lie about how the data was produced.
    let configuration: DetectorConfiguration
    private let sensitivity: SensitivityPreset

    // MARK: - Engines

    private var detector: OnlineAnomalyDetector
    private var calibrationEngine: CalibrationEngine
    private var clusterEngine: ClusterEngine
    private let qualityGate: ScanQualityGate

    // MARK: - Observable state

    private(set) var phase: Phase = .preparing
    private(set) var readout = LiveReadout()
    private(set) var clusters: [AnomalyCluster] = []
    private(set) var calibration: CalibrationSummary?
    private(set) var calibrationProgress: Double = 0
    private(set) var calibrationRejection: CalibrationRejection?
    private(set) var obstruction: QualityReason?
    private(set) var passIndex = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var draftRecord: ScanRecord?
    private(set) var saveError: String?
    private(set) var isSaving = false

    /// Walls ARKit has found, filtered to those big enough to scan.
    var candidateWalls: [DetectedWall] {
        spatialProvider.detectedWalls.filter(\.isUsableAsWall)
    }

    var lockedWall: LockedWall? { spatialProvider.lockedWall }
    var targetedWallID: UUID? { spatialProvider.targetedWallID }
    var trackingQuality: TrackingQuality { spatialProvider.trackingQuality }
    var currentHit: WallHit? { spatialProvider.currentHit }
    var availability: MagneticFieldAvailability { fieldService.availability }
    var arSessionController: ARSessionController? { spatialProvider as? ARSessionController }

    var isWallOverlayVisible: Bool {
        get { spatialProvider.isWallOverlayVisible }
        set {
            spatialProvider.isWallOverlayVisible = newValue
            preferences.wallOverlayVisible = newValue
        }
    }

    // MARK: - Private state

    private var sampleTask: Task<Void, Never>?
    private var readoutLimiter = RateLimiter(hz: Theme.readoutUpdatesPerSecond)
    private var scanStartMonotonic: TimeInterval?
    private var scanStartDate: Date?
    private var accumulatedDuration: TimeInterval = 0
    private var rejectionCounts: [String: Int] = [:]
    private var candidatesProduced = 0
    private var candidatesAccepted = 0
    private var timingErrors: [TimeInterval] = []
    private var cameraSpeeds: [Double] = []
    private var trackingNormalSamples = 0
    private var trackingTotalSamples = 0
    private var lastObservedProblem: ARSessionProblem?
    private var idleTimerDisabled = false

    // MARK: - Init

    init(
        fieldService: any MagneticFieldProviding,
        spatialProvider: any ARSpatialProviding,
        preferences: AppPreferences,
        scanStore: any ScanStoring,
        feedback: FeedbackController,
        capabilities: DeviceCapabilities,
        isSimulated: Bool,
        simulatedEnvironment: SimulatedEnvironment?,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) {
        self.fieldService = fieldService
        self.spatialProvider = spatialProvider
        self.preferences = preferences
        self.scanStore = scanStore
        self.feedback = feedback
        self.capabilities = capabilities
        self.isSimulated = isSimulated
        self.simulatedEnvironment = simulatedEnvironment
        self.clock = clock

        let configuration = preferences.detectorConfiguration
        self.configuration = configuration
        self.sensitivity = preferences.sensitivity
        self.detector = OnlineAnomalyDetector(configuration: configuration)
        self.calibrationEngine = CalibrationEngine(configuration: configuration)
        self.clusterEngine = ClusterEngine(configuration: configuration)
        self.qualityGate = ScanQualityGate(configuration: configuration)
        spatialProvider.isWallOverlayVisible = preferences.wallOverlayVisible
    }

    // MARK: - Session lifecycle

    /// Starts the camera and the sensor. Called when the user leaves the
    /// preparation checklist, not before -- nothing is powered up while the user
    /// is still reading.
    func beginSession() {
        guard phase == .preparing else { return }
        feedback.hapticsEnabled = preferences.hapticsEnabled
        feedback.soundEnabled = preferences.soundEnabled
        feedback.prepare()

        spatialProvider.start()
        if let problem = spatialProvider.problem {
            phase = .blocked(problem)
            return
        }
        startSampling()
        phase = .mappingWall
    }

    private func startSampling() {
        sampleTask?.cancel()
        let stream = fieldService.start(preferredSampleRate: 50)
        sampleTask = Task { @MainActor [weak self] in
            for await sample in stream {
                guard let self else { break }
                self.process(sample)
            }
        }
    }

    /// Stops all hardware. Safe to call more than once.
    func teardown() {
        sampleTask?.cancel()
        sampleTask = nil
        fieldService.stop()
        spatialProvider.stop()
        feedback.release()
        setIdleTimerDisabled(false)
    }

    /// Called when the app leaves the foreground.
    func handleBackgrounding() {
        guard phase == .scanning || phase == .calibrating else {
            setIdleTimerDisabled(false)
            return
        }
        pause()
    }

    // MARK: - Wall selection

    /// Locks whichever wall the crosshair is currently on.
    func lockTargetedWall() {
        guard let id = targetedWallID else {
            obstruction = .noWallIntersection
            feedback.refused()
            return
        }
        lockWall(id: id)
    }

    func lockWall(id: UUID) {
        guard spatialProvider.lockWall(id: id) else {
            obstruction = .wallNotLocked
            feedback.refused()
            return
        }
        obstruction = nil
        phase = .wallLocked
        feedback.stageCompleted()
    }

    func unlockWall() {
        spatialProvider.unlockWall()
        detector.invalidateCalibration()
        calibration = nil
        phase = .mappingWall
    }

    // MARK: - Calibration

    func startCalibration() {
        guard phase == .wallLocked || phase == .scanning || phase == .paused else { return }
        calibrationEngine.reset()
        calibrationProgress = 0
        calibrationRejection = nil
        detector.invalidateCalibration()
        calibration = nil
        phase = .calibrating
        simulatedEnvironment?.holdStill()
    }

    func cancelCalibration() {
        guard phase == .calibrating else { return }
        calibrationEngine.reset()
        calibrationProgress = 0
        phase = lockedWall == nil ? .mappingWall : .wallLocked
    }

    // MARK: - Scanning

    func startScanning() {
        guard calibration != nil else { return }
        guard phase == .wallLocked || phase == .paused || phase == .calibrating else { return }
        if scanStartMonotonic == nil { scanStartMonotonic = clock.now }
        // Separate from the monotonic mark on purpose. `accumulateDuration`
        // clears the monotonic mark on every pause, so folding both into one
        // check would restamp `createdAt` as the last resume rather than the
        // moment the scan actually began.
        if scanStartDate == nil { scanStartDate = Date() }
        phase = .scanning
        setIdleTimerDisabled(true)
        simulatedEnvironment?.beginSweeping()
    }

    func pause() {
        guard phase == .scanning || phase == .calibrating else { return }
        accumulateDuration()
        phase = .paused
        setIdleTimerDisabled(false)
        simulatedEnvironment?.holdStill()
    }

    func resume() {
        guard phase == .paused else { return }
        guard calibration != nil else {
            phase = .wallLocked
            return
        }
        scanStartMonotonic = clock.now
        phase = .scanning
        setIdleTimerDisabled(true)
        simulatedEnvironment?.beginSweeping()
    }

    /// Begins a new pass. A cluster only becomes `repeated` when a later pass
    /// measures the same place again, so this is how repeated evidence is
    /// gathered.
    func beginNewPass() {
        passIndex += 1
        feedback.stageCompleted()
    }

    @discardableResult
    func undoLastCluster() -> Bool {
        guard let removed = clusterEngine.undoLastCluster() else { return false }
        spatialProvider.removeClusterMarker(id: removed.id)
        clusters = clusterEngine.clusters
        return true
    }

    /// Clears every marker and measurement but keeps the locked wall and the
    /// baseline, so the user can start the sweep again without recalibrating.
    func resetMeasurements() {
        clusterEngine.removeAll()
        spatialProvider.removeAllClusterMarkers()
        clusters = []
        passIndex = 0
        rejectionCounts.removeAll()
        candidatesProduced = 0
        candidatesAccepted = 0
        timingErrors.removeAll()
        cameraSpeeds.removeAll()
        trackingNormalSamples = 0
        trackingTotalSamples = 0
        accumulatedDuration = 0
        scanStartMonotonic = phase == .scanning ? clock.now : nil
        scanStartDate = phase == .scanning ? Date() : nil
        elapsed = 0
    }

    // MARK: - Finishing

    /// Builds the draft record and moves to review. Nothing is written to disk
    /// until the user saves.
    func finish() {
        accumulateDuration()
        setIdleTimerDisabled(false)
        simulatedEnvironment?.holdStill()

        guard let calibration, let wall = lockedWall else {
            phase = .blocked(.sessionFailed("The scan ended before a baseline and a wall were established."))
            return
        }

        var metadata = wall.metadata
        metadata.coveredBounds = clusterEngine.coveredBounds

        let summary = ScanQualitySummary(
            candidatesProduced: candidatesProduced,
            candidatesAccepted: candidatesAccepted,
            rejectionCounts: rejectionCounts,
            meanTimingError: RobustStatistics.mean(timingErrors) ?? 0,
            worstTimingError: timingErrors.max() ?? 0,
            meanCameraSpeed: RobustStatistics.mean(cameraSpeeds) ?? 0,
            trackingNormalFraction: trackingTotalSamples > 0
                ? Double(trackingNormalSamples) / Double(trackingTotalSamples)
                : 0,
            measuredSampleRate: fieldService.timingHealth.measuredRate,
            passCount: passIndex + 1
        )

        draftRecord = ScanRecord(
            name: preferences.nextScanName(),
            createdAt: scanStartDate ?? Date(),
            updatedAt: Date(),
            duration: accumulatedDuration,
            appVersion: Branding.versionDisplayString,
            algorithmVersion: AlgorithmVersion.current,
            device: DeviceMetadata.current(capabilities: capabilities),
            isSimulated: isSimulated,
            detectorConfiguration: configuration,
            sensitivity: sensitivity,
            calibration: calibration,
            wall: metadata,
            measurements: clusterEngine.measurements,
            clusters: clusterEngine.clusters,
            quality: summary
        )
        phase = .finished
    }

    /// Persists the draft with the user's edits.
    func save(name: String, notes: String, tags: [String]) async -> Bool {
        guard var record = draftRecord else { return false }
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.notes = notes
        record.validationTags = tags
        record.updatedAt = Date()

        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await scanStore.save(record)
            preferences.incrementScanCounter()
            draftRecord = record
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    func discardDraft() {
        draftRecord = nil
    }

    // MARK: - Sample processing

    private func process(_ sample: MagneticFieldSample) {
        observeSessionProblem()
        updateElapsed()

        var pending = readout
        pending.magnitude = sample.magnitude
        pending.accuracy = sample.accuracy
        pending.timing = fieldService.timingHealth
        pending.source = sample.source

        let newest = spatialProvider.newestSpatialSample
        pending.wallDistance = newest?.hit?.distanceFromCamera
        pending.cameraSpeed = newest?.cameraSpeed ?? 0
        // Only sampled while measuring. `trackingNormalFraction` describes the
        // scan; counting the wall-mapping phase -- where tracking is routinely
        // limited while ARKit finds planes -- would understate it for reasons
        // that have nothing to do with the readings.
        if let newest, phase == .scanning {
            trackingTotalSamples += 1
            if newest.tracking.permitsPlacement { trackingNormalSamples += 1 }
        }

        switch phase {
        case .calibrating:
            processCalibration(sample)
        case .scanning:
            pending = processScanning(sample, pending: pending)
        case .preparing, .mappingWall, .wallLocked, .paused, .finished, .blocked:
            break
        }

        // Assigned only when it changes. `@Observable` has no equality check in
        // its setter, so writing the same value still invalidates every view
        // reading it -- which at sensor rate would redraw the HUD 50 times a
        // second and defeat the throttle below.
        let liveObstruction = qualityGate.liveObstruction(
            availability: fieldService.availability,
            timing: fieldService.timingHealth,
            isCalibrated: calibration != nil,
            isWallLocked: lockedWall != nil,
            accuracy: sample.accuracy,
            newest: newest
        )
        if liveObstruction != obstruction { obstruction = liveObstruction }

        // Throttled publication: the sensor runs at ~50 Hz, the HUD at 10 Hz.
        if readoutLimiter.allow(at: sample.timestamp) {
            readout = pending
        }
    }

    private func processCalibration(_ sample: MagneticFieldSample) {
        let progress = calibrationEngine.ingest(
            sample,
            tracking: spatialProvider.trackingQuality,
            requireTracking: !isSimulated
        )
        switch progress {
        case .collecting(let fraction, _, _):
            calibrationProgress = fraction
        case .rejected(let reason):
            calibrationProgress = 0
            calibrationRejection = reason
            feedback.refused()
            phase = lockedWall == nil ? .mappingWall : .wallLocked
        case .completed(let summary):
            calibrationProgress = 1
            calibrationRejection = nil
            calibration = summary
            detector.adopt(calibration: summary)
            feedback.stageCompleted()
            phase = .wallLocked
        }
    }

    private func processScanning(_ sample: MagneticFieldSample, pending: LiveReadout) -> LiveReadout {
        var pending = pending
        let output = detector.ingest(sample)
        pending.smoothedMagnitude = output.smoothedMagnitude
        pending.baseline = output.baseline
        pending.delta = output.delta
        pending.robustZScore = output.robustZScore
        pending.sigma = output.sigma
        pending.gradient = output.gradient
        pending.detectorState = output.state

        guard let candidate = output.candidate else { return pending }
        candidatesProduced += 1

        let match = spatialProvider.spatialMatch(
            for: candidate.timestamp,
            tolerance: configuration.timestampTolerance
        )
        let verdict = qualityGate.evaluate(
            ScanQualityInputs(
                availability: fieldService.availability,
                timing: fieldService.timingHealth,
                isCalibrated: calibration != nil,
                isWallLocked: lockedWall != nil,
                candidate: candidate,
                match: match,
                clusterCount: clusterEngine.clusters.count
            )
        )

        guard verdict.accepts, let match else {
            for reason in verdict.blocking {
                rejectionCounts[reason.rawValue, default: 0] += 1
            }
            return pending
        }

        let outcome = clusterEngine.add(
            candidate: candidate,
            match: match,
            passIndex: passIndex,
            scanStart: scanStartMonotonic ?? candidate.timestamp,
            date: Date()
        )

        switch outcome {
        case .created(let cluster):
            candidatesAccepted += 1
            record(match: match)
            clusters = clusterEngine.clusters
            spatialProvider.renderCluster(cluster)
            if clusterEngine.shouldPulseHaptic(for: cluster.id, at: candidate.timestamp) {
                feedback.newCluster()
            }
        case .updated(let cluster):
            candidatesAccepted += 1
            record(match: match)
            clusters = clusterEngine.clusters
            spatialProvider.renderCluster(cluster)
            if cluster.confidence == .repeated,
               clusterEngine.shouldPulseHaptic(for: cluster.id, at: candidate.timestamp) {
                feedback.repeatedCluster()
            }
        case .rejected(let reason):
            rejectionCounts[reason.rawValue, default: 0] += 1
        }
        return pending
    }

    private func record(match: SpatialMatch) {
        timingErrors.append(match.timingError)
        cameraSpeeds.append(match.sample.cameraSpeed)
        // Bounded: these feed a mean and a maximum, so a scan lasting many
        // minutes must not accumulate an unbounded array.
        if timingErrors.count > configuration.maximumMeasurements {
            timingErrors.removeFirst(timingErrors.count - configuration.maximumMeasurements)
        }
        if cameraSpeeds.count > configuration.maximumMeasurements {
            cameraSpeeds.removeFirst(cameraSpeeds.count - configuration.maximumMeasurements)
        }
    }

    private func observeSessionProblem() {
        let problem = spatialProvider.problem
        guard problem != lastObservedProblem else { return }
        lastObservedProblem = problem
        guard let problem else { return }
        if phase == .scanning || phase == .calibrating {
            accumulateDuration()
            setIdleTimerDisabled(false)
        }
        phase = .blocked(problem)
    }

    /// Attempts to continue after a recoverable interruption.
    func retryAfterProblem() {
        guard case .blocked(let problem) = phase, problem.isRecoverable else { return }
        spatialProvider.resume()
        phase = lockedWall == nil ? .mappingWall : (calibration == nil ? .wallLocked : .paused)
    }

    /// Republishes `elapsed` at a tenth of a second.
    ///
    /// It is rendered as `M:SS`, so a finer step would invalidate the HUD at
    /// sensor rate to show a number that cannot change. `accumulateDuration` and
    /// `resetMeasurements` still write exact values, so the stored duration is
    /// never approximate.
    private func updateElapsed() {
        guard let start = scanStartMonotonic, phase == .scanning else { return }
        let updated = accumulatedDuration + max(0, clock.now - start)
        if abs(updated - elapsed) >= 0.1 { elapsed = updated }
    }

    private func accumulateDuration() {
        guard let start = scanStartMonotonic else { return }
        accumulatedDuration += max(0, clock.now - start)
        scanStartMonotonic = nil
        elapsed = accumulatedDuration
    }

    /// The idle timer is disabled only while actively measuring, and is always
    /// restored -- including on teardown, on backgrounding and on any blocking
    /// problem.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        guard idleTimerDisabled != disabled else { return }
        idleTimerDisabled = disabled
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

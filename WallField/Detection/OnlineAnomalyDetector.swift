import Foundation

/// The online magnetic anomaly detector.
///
/// # What it decides
///
/// For every incoming sample it answers one question: *is the measured field
/// magnitude right now different from this room's quiet baseline by more than
/// this session's noise can explain, persistently enough to be worth recording?*
///
/// It never answers what caused the difference.
///
/// # The pipeline
///
/// 1. **Median smoothing** over `smoothingWindow` samples. A median, not a mean,
///    so a single wild sample is discarded outright rather than averaged in.
/// 2. **Deviation** of the smoothed magnitude from a slow baseline.
/// 3. **Robust z-score**, `|delta| / sigma`, where sigma came from the MAD
///    measured during calibration on the same smoothed series.
/// 4. **Dual threshold.** A candidate must clear both an adaptive threshold
///    (`enterZScore` sigmas) and an absolute floor (`absoluteFloorMicrotesla`).
///    The adaptive term stops a noisy environment from producing marks; the
///    absolute floor stops an unusually quiet environment from promoting
///    physically meaningless wobbles.
/// 5. **Persistence.** At least `persistenceRequired` of the last
///    `persistenceWindow` samples must clear the threshold, so no isolated
///    sample can ever produce a marker. Nothing may arm until the median window
///    is full, so a spike arriving in the first samples after calibration
///    cannot slip past while the smoothing is still warming up.
/// 6. **Hysteresis.** Once active, the event only ends when the signal falls
///    below the lower exit thresholds, so a reading hovering at the boundary
///    does not chatter.
/// 7. **Refractory period.** At most one candidate per `refractoryInterval`, so
///    one physical peak yields a handful of candidates to cluster rather than
///    fifty.
/// 8. **Baseline adaptation.** The slow baseline follows genuine environmental
///    drift, but only absorbs samples below `baselineUpdateMaxZScore` and never
///    while an event is in progress -- otherwise a real anomaly would quietly
///    become the new normal and erase itself.
///
/// Both polarities are detected: ferrous material can concentrate or shield the
/// local field, so a drop below baseline is as real a measurement as a rise.
struct OnlineAnomalyDetector: AnomalyDetecting {
    let configuration: DetectorConfiguration

    // MARK: - State

    private enum Phase {
        case uncalibrated
        case idle
        case arming
        case active
    }

    private var phase: Phase = .uncalibrated
    private var storedBaseline: Double?
    private var storedSigma: Double?
    private var smoothingSamples: BoundedBuffer<Double>
    private var smoothedHistory: BoundedBuffer<SmoothedPoint>
    private var exceedanceHistory: BoundedBuffer<Bool>
    private var lastEmission: TimeInterval?
    private var lastTimestamp: TimeInterval?

    private struct SmoothedPoint {
        var timestamp: TimeInterval
        var value: Double
    }

    // MARK: - Init

    init(configuration: DetectorConfiguration = .default) {
        let sanitized = configuration.sanitized()
        self.configuration = sanitized
        self.smoothingSamples = BoundedBuffer(capacity: sanitized.smoothingWindow)
        self.smoothedHistory = BoundedBuffer(capacity: max(sanitized.gradientLookback + 1, 8))
        self.exceedanceHistory = BoundedBuffer(capacity: sanitized.persistenceWindow)
    }

    // MARK: - AnomalyDetecting

    var baseline: Double? { storedBaseline }
    var sigma: Double? { storedSigma }

    var state: DetectorState {
        switch phase {
        case .uncalibrated: return .uncalibrated
        case .idle: return .idle
        case .arming: return .arming
        case .active: return isWithinRefractory ? .refractory : .active
        }
    }

    mutating func adopt(calibration: CalibrationSummary) {
        storedBaseline = calibration.baselineMagnitude
        storedSigma = max(calibration.sigma, configuration.minimumSigma)
        phase = .idle
        clearWindows()
    }

    mutating func invalidateCalibration() {
        storedBaseline = nil
        storedSigma = nil
        phase = .uncalibrated
        clearWindows()
    }

    mutating func ingest(_ sample: MagneticFieldSample) -> DetectorOutput {
        guard sample.isFinite else {
            return neutralOutput(for: sample, smoothed: smoothedHistory.last?.value ?? 0)
        }

        smoothingSamples.append(sample.magnitude)
        let smoothed = RobustStatistics.median(smoothingSamples.elements) ?? sample.magnitude
        smoothedHistory.append(SmoothedPoint(timestamp: sample.timestamp, value: smoothed))

        guard let sigmaValue = storedSigma, var baselineValue = storedBaseline else {
            lastTimestamp = sample.timestamp
            return neutralOutput(for: sample, smoothed: smoothed)
        }

        let delta = smoothed - baselineValue
        let zScore = RobustStatistics.robustZScore(value: smoothed, centre: baselineValue, sigma: sigmaValue)
        let gradient = computeGradient()

        // Until the median window is full the smoothing that rejects isolated
        // spikes is not yet in force, so nothing may arm. Without this, a spike
        // landing on the first samples after calibration -- exactly when the
        // window is empty -- would slip past the persistence rule.
        let isWarmingUp = smoothingSamples.count < configuration.smoothingWindow

        let clearsEnter = !isWarmingUp
            && zScore >= configuration.enterZScore
            && abs(delta) >= configuration.absoluteFloorMicrotesla
        let clearsSustain = !isWarmingUp
            && zScore >= configuration.exitZScore
            && abs(delta) >= configuration.absoluteFloorMicrotesla * configuration.exitFloorFraction

        exceedanceHistory.append(clearsEnter)
        let persistence = exceedanceHistory.elements.reduce(0) { $0 + ($1 ? 1 : 0) }

        var emitted: AnomalyCandidate?

        switch phase {
        case .uncalibrated:
            break

        case .idle, .arming:
            if clearsEnter {
                phase = .arming
                if persistence >= configuration.persistenceRequired, refractoryElapsed(at: sample.timestamp) {
                    phase = .active
                    lastEmission = sample.timestamp
                    emitted = makeCandidate(
                        sample: sample, smoothed: smoothed, baseline: baselineValue,
                        sigma: sigmaValue, delta: delta, zScore: zScore,
                        gradient: gradient, persistence: persistence
                    )
                }
            } else {
                phase = .idle
            }

        case .active:
            if clearsSustain {
                if clearsEnter,
                   persistence >= configuration.persistenceRequired,
                   refractoryElapsed(at: sample.timestamp) {
                    lastEmission = sample.timestamp
                    emitted = makeCandidate(
                        sample: sample, smoothed: smoothed, baseline: baselineValue,
                        sigma: sigmaValue, delta: delta, zScore: zScore,
                        gradient: gradient, persistence: persistence
                    )
                }
            } else {
                phase = .idle
            }
        }

        // Baseline adaptation: only while genuinely quiet.
        if phase == .idle, zScore < configuration.baselineUpdateMaxZScore {
            let dt = interval(for: sample)
            let alpha = 1 - exp(-dt / configuration.baselineTimeConstant)
            baselineValue += alpha * (smoothed - baselineValue)
            storedBaseline = baselineValue
        }

        lastTimestamp = sample.timestamp

        return DetectorOutput(
            sample: sample,
            smoothedMagnitude: smoothed,
            baseline: baselineValue,
            sigma: sigmaValue,
            delta: delta,
            robustZScore: zScore,
            gradient: gradient,
            persistence: persistence,
            state: state,
            candidate: emitted
        )
    }

    // MARK: - Helpers

    private var isWithinRefractory: Bool {
        guard let lastEmission, let lastTimestamp else { return false }
        return lastTimestamp - lastEmission < configuration.refractoryInterval
    }

    private func refractoryElapsed(at timestamp: TimeInterval) -> Bool {
        guard let lastEmission else { return true }
        return timestamp - lastEmission >= configuration.refractoryInterval
    }

    /// Delivered interval for the sample, falling back to the measured gap and
    /// finally to a sane default, so baseline adaptation never divides by zero
    /// or absorbs a whole scan in one step after a stall.
    private func interval(for sample: MagneticFieldSample) -> TimeInterval {
        if sample.interval > 0, sample.interval.isFinite {
            return min(sample.interval, configuration.baselineTimeConstant)
        }
        if let lastTimestamp, sample.timestamp > lastTimestamp {
            return min(sample.timestamp - lastTimestamp, configuration.baselineTimeConstant)
        }
        return 0.02
    }

    /// Rate of change of the smoothed magnitude, µT/s, over `gradientLookback`
    /// samples. Zero until enough history exists.
    private func computeGradient() -> Double {
        guard let newest = smoothedHistory.last,
              let older = smoothedHistory.fromEnd(configuration.gradientLookback)
        else { return 0 }
        let dt = newest.timestamp - older.timestamp
        guard dt > 0 else { return 0 }
        return (newest.value - older.value) / dt
    }

    private func makeCandidate(
        sample: MagneticFieldSample,
        smoothed: Double,
        baseline: Double,
        sigma: Double,
        delta: Double,
        zScore: Double,
        gradient: Double,
        persistence: Int
    ) -> AnomalyCandidate {
        AnomalyCandidate(
            id: UUID(),
            timestamp: sample.timestamp,
            sample: sample,
            smoothedMagnitude: smoothed,
            baseline: baseline,
            delta: delta,
            robustZScore: zScore,
            gradient: gradient,
            persistence: persistence,
            sigma: sigma
        )
    }

    private func neutralOutput(for sample: MagneticFieldSample, smoothed: Double) -> DetectorOutput {
        DetectorOutput(
            sample: sample,
            smoothedMagnitude: smoothed,
            baseline: storedBaseline ?? 0,
            sigma: storedSigma ?? 0,
            delta: 0,
            robustZScore: 0,
            gradient: 0,
            persistence: 0,
            state: state,
            candidate: nil
        )
    }

    private mutating func clearWindows() {
        smoothingSamples.removeAll()
        smoothedHistory.removeAll()
        exceedanceHistory.removeAll()
        lastEmission = nil
        lastTimestamp = nil
    }
}

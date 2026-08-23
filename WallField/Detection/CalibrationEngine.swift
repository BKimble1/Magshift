import Foundation

/// Progress of a baseline calibration attempt.
enum CalibrationProgress: Sendable, Equatable {
    /// Still collecting. `fraction` is `0...1` against the longer of the
    /// duration and sample-count requirements.
    case collecting(fraction: Double, elapsed: TimeInterval, sampleCount: Int)
    /// Refused. The engine has reset itself; the caller shows the reason and may
    /// start again.
    case rejected(CalibrationRejection)
    /// A usable baseline was measured.
    case completed(CalibrationSummary)

    var isTerminal: Bool {
        switch self {
        case .collecting: return false
        case .rejected, .completed: return true
        }
    }
}

/// Collects a quiet local baseline and the noise around it.
///
/// # Why calibration is refused rather than degraded
///
/// Everything downstream is expressed relative to this baseline. A baseline
/// measured while the phone was moving, while the magnetometer reported poor
/// calibration accuracy, or while the field was swinging wildly would not merely
/// be imprecise -- it would silently mis-scale every z-score for the rest of the
/// scan. So each of those conditions aborts the attempt and tells the user what
/// to change.
struct CalibrationEngine {
    let configuration: DetectorConfiguration

    private var magnitudes: [Double] = []
    private var vectors: [Vector3] = []
    private var accuracies: [MagneticFieldAccuracy] = []
    private var intervals: [TimeInterval] = []
    private var startTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var source: MagneticFieldSource?

    /// Number of accepted samples so far.
    var sampleCount: Int { magnitudes.count }
    /// Seconds of accepted samples so far.
    var elapsed: TimeInterval {
        guard let start = startTimestamp, let last = lastTimestamp else { return 0 }
        return max(0, last - start)
    }

    init(configuration: DetectorConfiguration) {
        self.configuration = configuration.sanitized()
    }

    mutating func reset() {
        magnitudes.removeAll(keepingCapacity: true)
        vectors.removeAll(keepingCapacity: true)
        accuracies.removeAll(keepingCapacity: true)
        intervals.removeAll(keepingCapacity: true)
        startTimestamp = nil
        lastTimestamp = nil
        source = nil
    }

    /// Feeds one sample.
    ///
    /// - Parameters:
    ///   - sample: the field reading.
    ///   - tracking: AR tracking state at the same moment. Calibration requires
    ///     normal tracking because the user is being asked to hold the phone
    ///     against a specific spot on a specific wall.
    ///   - requireTracking: `false` for the Diagnostics lab, which calibrates
    ///     without an AR session at all.
    mutating func ingest(
        _ sample: MagneticFieldSample,
        tracking: TrackingQuality,
        requireTracking: Bool = true
    ) -> CalibrationProgress {
        guard sample.isFinite else {
            return .collecting(fraction: progressFraction, elapsed: elapsed, sampleCount: sampleCount)
        }
        guard sample.source.isAcceptableForDetection else {
            reset()
            return .rejected(.unsupportedSource)
        }
        guard sample.accuracy.isAcceptable else {
            reset()
            return .rejected(.accuracyTooLow)
        }
        if requireTracking, !tracking.permitsPlacement {
            reset()
            return .rejected(.trackingNotNormal)
        }
        if let motion = sample.motion, !motion.isSteady {
            reset()
            return .rejected(.excessiveMotion)
        }

        if startTimestamp == nil {
            startTimestamp = sample.timestamp
            source = sample.source
        }
        lastTimestamp = sample.timestamp
        magnitudes.append(sample.magnitude)
        vectors.append(Vector3(x: Float(sample.x), y: Float(sample.y), z: Float(sample.z)))
        accuracies.append(sample.accuracy)
        if sample.interval > 0 { intervals.append(sample.interval) }

        guard sampleCount >= configuration.calibrationMinimumSamples,
              elapsed >= configuration.calibrationMinimumDuration
        else {
            return .collecting(fraction: progressFraction, elapsed: elapsed, sampleCount: sampleCount)
        }
        return finish()
    }

    /// `0...1` progress against whichever requirement is furthest from being met.
    var progressFraction: Double {
        let byDuration = elapsed / configuration.calibrationMinimumDuration
        let bySamples = Double(sampleCount) / Double(configuration.calibrationMinimumSamples)
        return min(1, max(0, min(byDuration, bySamples)))
    }

    /// Evaluates the collected data. Called automatically once both minimums are
    /// met; exposed so tests can force an evaluation.
    mutating func finish() -> CalibrationProgress {
        guard sampleCount >= 2 else {
            reset()
            return .rejected(.notEnoughSamples)
        }
        guard elapsed >= configuration.calibrationMinimumDuration else {
            reset()
            return .rejected(.notEnoughDuration)
        }
        guard let baseline = RobustStatistics.median(magnitudes),
              let rawMAD = RobustStatistics.medianAbsoluteDeviation(magnitudes),
              let range = RobustStatistics.range(magnitudes)
        else {
            reset()
            return .rejected(.notEnoughSamples)
        }

        // Noise is measured on the same smoothed series the online detector
        // scores against, so a z-score during scanning means what it says.
        let smoothed = CalibrationEngine.rollingMedian(magnitudes, window: configuration.smoothingWindow)
        guard let smoothedMAD = RobustStatistics.medianAbsoluteDeviation(smoothed) else {
            reset()
            return .rejected(.notEnoughSamples)
        }

        let unflooredSigma = RobustStatistics.madToSigma * smoothedMAD
        let sigma = max(unflooredSigma, configuration.minimumSigma)
        let wasFloored = sigma > unflooredSigma

        if unflooredSigma > configuration.calibrationMaximumSigma {
            reset()
            return .rejected(.fieldTooNoisy)
        }
        if range > configuration.calibrationMaximumRange {
            reset()
            return .rejected(.fieldRangeTooLarge)
        }

        let meanInterval = RobustStatistics.mean(intervals) ?? 0
        let measuredRate = meanInterval > 0 ? 1 / meanInterval : 0
        let maximumGap = intervals.max() ?? 0
        let timing = SampleTimingHealth(
            measuredRate: measuredRate,
            meanInterval: meanInterval,
            maximumGap: maximumGap,
            sampleCount: sampleCount
        )
        guard timing.isHealthy else {
            reset()
            return .rejected(.sampleTimingUnstable)
        }

        let count = Double(vectors.count)
        let meanVector = Vector3(
            x: Float(vectors.reduce(0.0) { $0 + Double($1.x) } / count),
            y: Float(vectors.reduce(0.0) { $0 + Double($1.y) } / count),
            z: Float(vectors.reduce(0.0) { $0 + Double($1.z) } / count)
        )

        let summary = CalibrationSummary(
            baselineMagnitude: baseline,
            sigma: sigma,
            medianAbsoluteDeviation: smoothedMAD,
            rawMedianAbsoluteDeviation: rawMAD,
            sigmaWasFloored: wasFloored,
            range: range,
            meanVector: meanVector,
            sampleCount: sampleCount,
            duration: elapsed,
            worstAccuracy: accuracies.min() ?? .uncalibrated,
            measuredSampleRate: measuredRate,
            source: source ?? .calibratedDeviceMotion,
            completedAt: Date()
        )
        reset()
        return .completed(summary)
    }

    /// Rolling median with the same window the online detector uses. The first
    /// `window - 1` outputs use whatever history exists, matching the detector's
    /// warm-up behaviour exactly.
    static func rollingMedian(_ values: [Double], window: Int) -> [Double] {
        guard window > 1 else { return values }
        var output: [Double] = []
        output.reserveCapacity(values.count)
        var recent: [Double] = []
        recent.reserveCapacity(window)
        for value in values {
            recent.append(value)
            if recent.count > window { recent.removeFirst() }
            output.append(RobustStatistics.median(recent) ?? value)
        }
        return output
    }
}

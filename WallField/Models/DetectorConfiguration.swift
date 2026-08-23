import Foundation

/// The algorithm's identity, stored with every scan.
///
/// Bump `AlgorithmVersion.current` whenever a change would alter the readings a
/// given physical wall produces, so historical scans remain interpretable and so
/// validation runs can be attributed to the exact algorithm that produced them.
enum AlgorithmVersion {
    /// Semantic version of the detection/clustering pipeline.
    ///
    /// The `-provisional` suffix is deliberate and must not be removed until the
    /// thresholds in `DetectorConfiguration` have been measured against known
    /// ground truth on physical devices. See `Docs/VALIDATION_PROTOCOL.md`.
    static let current = "1.0.0-provisional"

    /// True while the thresholds are still unvalidated against physical ground
    /// truth. Drives the "provisional thresholds" note in diagnostics.
    static var isProvisional: Bool { current.contains("provisional") }
}

/// User-selectable sensitivity.
///
/// Sensitivity changes the *statistical* thresholds only. It never changes what
/// the app claims a reading is, and no preset makes the app able to detect an
/// object type.
enum SensitivityPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var explanation: String {
        switch self {
        case .low:
            return "Only large, very clearly repeated changes are marked. Fewest false marks."
        case .medium:
            return "Balanced. The recommended starting point."
        case .high:
            return "Marks smaller changes. Expect noticeably more marks caused by noise and by objects that have nothing to do with the wall."
        }
    }
}

/// Every tunable constant in the detection pipeline, in one auditable place.
///
/// # Provisional status
///
/// The default values below are **provisional**. They were chosen to be
/// conservative -- to favour missing a real anomaly over inventing one -- and
/// they have not yet been measured against known ground truth on physical
/// hardware. `Docs/VALIDATION_PROTOCOL.md` defines the experiments that must be
/// run before these numbers can be described as validated, and every scan
/// persists the exact configuration it ran with so past results stay
/// interpretable after the numbers change.
///
/// # Why there is no absolute threshold
///
/// There is deliberately no rule of the form "anything above 50 µT is metal".
/// Earth's field varies with location and the indoor environment varies far
/// more, so any fixed absolute cut-off is indefensible. Detection is relative to
/// a baseline measured in *this* room, scaled by noise measured in *this*
/// session, with an absolute floor used only to suppress statistically
/// significant but physically trivial wobbles.
struct DetectorConfiguration: Codable, Sendable, Hashable {

    // MARK: - Sensitivity-dependent thresholds

    /// Robust z-score at which a candidate becomes active.
    var enterZScore: Double
    /// Robust z-score below which an active candidate ends (hysteresis).
    var exitZScore: Double
    /// Minimum absolute deviation from baseline, µT, required to enter.
    var absoluteFloorMicrotesla: Double
    /// Fraction of `absoluteFloorMicrotesla` at which an active event ends.
    var exitFloorFraction: Double
    /// Of the last `persistenceWindow` samples, how many must exceed threshold.
    var persistenceRequired: Int

    // MARK: - Fixed statistical parameters

    /// Number of recent samples examined for persistence.
    var persistenceWindow: Int
    /// Number of samples in the short median-smoothing window.
    var smoothingWindow: Int
    /// Lower bound on estimated sigma, µT. A calibration that measures zero
    /// variance is not trusted; without this floor a perfectly quiet baseline
    /// would make every subsequent sample infinitely significant.
    var minimumSigma: Double
    /// Time constant, seconds, of the slow baseline that tracks environmental drift.
    var baselineTimeConstant: TimeInterval
    /// The slow baseline only absorbs samples below this z-score, so an anomaly
    /// can never quietly become the new normal.
    var baselineUpdateMaxZScore: Double
    /// Samples back used to compute the short-term gradient.
    var gradientLookback: Int
    /// Minimum seconds between two emitted candidates, so one physical peak does
    /// not produce dozens of markers.
    var refractoryInterval: TimeInterval

    // MARK: - Calibration

    /// Minimum seconds of accepted samples required for a baseline.
    var calibrationMinimumDuration: TimeInterval
    /// Minimum accepted sample count required for a baseline.
    var calibrationMinimumSamples: Int
    /// Calibration is rejected if the robust sigma exceeds this, µT: the
    /// environment is too noisy for a meaningful baseline.
    var calibrationMaximumSigma: Double
    /// Calibration is rejected if peak-to-peak magnitude exceeds this, µT.
    var calibrationMaximumRange: Double

    // MARK: - Spatial and timing gates

    /// Maximum permitted difference between a field sample's timestamp and the
    /// nearest recorded camera pose, seconds.
    var timestampTolerance: TimeInterval
    /// Maximum camera speed during placement, m/s.
    var maximumScanSpeed: Double
    /// Working range from the wall, metres.
    var minimumWallDistance: Double
    var maximumWallDistance: Double
    /// How far past the mapped plane edge an extrapolated raycast may land, metres.
    var maximumExtrapolationDistance: Double

    // MARK: - Clustering

    /// Candidates within this wall-space radius join the same cluster, metres.
    var clusterRadius: Double
    /// A later observation counts as a new pass only after this gap, seconds.
    var repeatPassMinimumInterval: TimeInterval
    /// Maximum simultaneously rendered clusters.
    var maximumClusters: Int
    /// Maximum stored measurements per scan.
    var maximumMeasurements: Int
    /// Minimum seconds between haptic pulses for the same cluster.
    var hapticRefractoryInterval: TimeInterval

    // MARK: - Presets

    /// The configuration for a sensitivity preset.
    static func preset(_ preset: SensitivityPreset) -> DetectorConfiguration {
        var config = DetectorConfiguration.base
        switch preset {
        case .low:
            config.enterZScore = 7.0
            config.exitZScore = 4.5
            config.absoluteFloorMicrotesla = 6.0
            config.persistenceRequired = 4
        case .medium:
            config.enterZScore = 5.0
            config.exitZScore = 3.0
            config.absoluteFloorMicrotesla = 4.0
            config.persistenceRequired = 3
        case .high:
            config.enterZScore = 4.0
            config.exitZScore = 2.5
            config.absoluteFloorMicrotesla = 2.5
            config.persistenceRequired = 3
        }
        return config
    }

    /// The recommended default.
    static let `default` = DetectorConfiguration.preset(.medium)

    /// Values shared by every preset. Sensitivity-dependent fields are
    /// overwritten by `preset(_:)`.
    private static let base = DetectorConfiguration(
        enterZScore: 5.0,
        exitZScore: 3.0,
        absoluteFloorMicrotesla: 4.0,
        exitFloorFraction: 0.6,
        persistenceRequired: 3,
        persistenceWindow: 5,
        smoothingWindow: 3,
        minimumSigma: 0.15,
        baselineTimeConstant: 8.0,
        baselineUpdateMaxZScore: 2.0,
        gradientLookback: 5,
        refractoryInterval: 0.35,
        calibrationMinimumDuration: 2.5,
        calibrationMinimumSamples: 100,
        calibrationMaximumSigma: 1.5,
        calibrationMaximumRange: 12.0,
        timestampTolerance: 0.100,
        maximumScanSpeed: 0.35,
        minimumWallDistance: 0.02,
        maximumWallDistance: 0.35,
        maximumExtrapolationDistance: 0.10,
        clusterRadius: 0.04,
        repeatPassMinimumInterval: 2.0,
        maximumClusters: 250,
        maximumMeasurements: 5000,
        hapticRefractoryInterval: 0.8
    )

    /// The preset this configuration matches, or `nil` if it has been changed.
    var matchingPreset: SensitivityPreset? {
        SensitivityPreset.allCases.first { DetectorConfiguration.preset($0) == self }
    }

    /// Guards against a decoded or hand-edited configuration that would make the
    /// detector nonsensical. Clamps rather than crashing, because a stored scan
    /// from a future version must never take the app down.
    func sanitized() -> DetectorConfiguration {
        var config = self
        config.enterZScore = max(1.0, config.enterZScore)
        config.exitZScore = min(max(0.5, config.exitZScore), config.enterZScore)
        config.absoluteFloorMicrotesla = max(0.1, config.absoluteFloorMicrotesla)
        config.exitFloorFraction = min(max(0.05, config.exitFloorFraction), 1.0)
        config.persistenceWindow = max(1, config.persistenceWindow)
        config.persistenceRequired = min(max(1, config.persistenceRequired), config.persistenceWindow)
        config.smoothingWindow = max(1, config.smoothingWindow)
        config.minimumSigma = max(0.001, config.minimumSigma)
        config.baselineTimeConstant = max(0.1, config.baselineTimeConstant)
        config.baselineUpdateMaxZScore = max(0.1, config.baselineUpdateMaxZScore)
        config.gradientLookback = max(1, config.gradientLookback)
        config.refractoryInterval = max(0, config.refractoryInterval)
        config.calibrationMinimumDuration = max(0.1, config.calibrationMinimumDuration)
        config.calibrationMinimumSamples = max(2, config.calibrationMinimumSamples)
        config.calibrationMaximumSigma = max(0.01, config.calibrationMaximumSigma)
        config.calibrationMaximumRange = max(0.01, config.calibrationMaximumRange)
        config.timestampTolerance = max(0.001, config.timestampTolerance)
        config.maximumScanSpeed = max(0.01, config.maximumScanSpeed)
        config.minimumWallDistance = max(0, config.minimumWallDistance)
        config.maximumWallDistance = max(config.minimumWallDistance + 0.01, config.maximumWallDistance)
        config.maximumExtrapolationDistance = max(0, config.maximumExtrapolationDistance)
        config.clusterRadius = max(0.005, config.clusterRadius)
        config.repeatPassMinimumInterval = max(0, config.repeatPassMinimumInterval)
        config.maximumClusters = max(1, config.maximumClusters)
        config.maximumMeasurements = max(1, config.maximumMeasurements)
        config.hapticRefractoryInterval = max(0, config.hapticRefractoryInterval)
        return config
    }

    /// Decoding tolerates missing keys by falling back to the medium preset for
    /// that field, so a scan written by an older build still opens.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DetectorConfiguration.base
        func value(_ key: CodingKeys, _ fallbackValue: Double) throws -> Double {
            try container.decodeIfPresent(Double.self, forKey: key) ?? fallbackValue
        }
        func intValue(_ key: CodingKeys, _ fallbackValue: Int) throws -> Int {
            try container.decodeIfPresent(Int.self, forKey: key) ?? fallbackValue
        }
        enterZScore = try value(.enterZScore, fallback.enterZScore)
        exitZScore = try value(.exitZScore, fallback.exitZScore)
        absoluteFloorMicrotesla = try value(.absoluteFloorMicrotesla, fallback.absoluteFloorMicrotesla)
        exitFloorFraction = try value(.exitFloorFraction, fallback.exitFloorFraction)
        persistenceRequired = try intValue(.persistenceRequired, fallback.persistenceRequired)
        persistenceWindow = try intValue(.persistenceWindow, fallback.persistenceWindow)
        smoothingWindow = try intValue(.smoothingWindow, fallback.smoothingWindow)
        minimumSigma = try value(.minimumSigma, fallback.minimumSigma)
        baselineTimeConstant = try value(.baselineTimeConstant, fallback.baselineTimeConstant)
        baselineUpdateMaxZScore = try value(.baselineUpdateMaxZScore, fallback.baselineUpdateMaxZScore)
        gradientLookback = try intValue(.gradientLookback, fallback.gradientLookback)
        refractoryInterval = try value(.refractoryInterval, fallback.refractoryInterval)
        calibrationMinimumDuration = try value(.calibrationMinimumDuration, fallback.calibrationMinimumDuration)
        calibrationMinimumSamples = try intValue(.calibrationMinimumSamples, fallback.calibrationMinimumSamples)
        calibrationMaximumSigma = try value(.calibrationMaximumSigma, fallback.calibrationMaximumSigma)
        calibrationMaximumRange = try value(.calibrationMaximumRange, fallback.calibrationMaximumRange)
        timestampTolerance = try value(.timestampTolerance, fallback.timestampTolerance)
        maximumScanSpeed = try value(.maximumScanSpeed, fallback.maximumScanSpeed)
        minimumWallDistance = try value(.minimumWallDistance, fallback.minimumWallDistance)
        maximumWallDistance = try value(.maximumWallDistance, fallback.maximumWallDistance)
        maximumExtrapolationDistance = try value(.maximumExtrapolationDistance, fallback.maximumExtrapolationDistance)
        clusterRadius = try value(.clusterRadius, fallback.clusterRadius)
        repeatPassMinimumInterval = try value(.repeatPassMinimumInterval, fallback.repeatPassMinimumInterval)
        maximumClusters = try intValue(.maximumClusters, fallback.maximumClusters)
        maximumMeasurements = try intValue(.maximumMeasurements, fallback.maximumMeasurements)
        hapticRefractoryInterval = try value(.hapticRefractoryInterval, fallback.hapticRefractoryInterval)
    }

    init(
        enterZScore: Double,
        exitZScore: Double,
        absoluteFloorMicrotesla: Double,
        exitFloorFraction: Double,
        persistenceRequired: Int,
        persistenceWindow: Int,
        smoothingWindow: Int,
        minimumSigma: Double,
        baselineTimeConstant: TimeInterval,
        baselineUpdateMaxZScore: Double,
        gradientLookback: Int,
        refractoryInterval: TimeInterval,
        calibrationMinimumDuration: TimeInterval,
        calibrationMinimumSamples: Int,
        calibrationMaximumSigma: Double,
        calibrationMaximumRange: Double,
        timestampTolerance: TimeInterval,
        maximumScanSpeed: Double,
        minimumWallDistance: Double,
        maximumWallDistance: Double,
        maximumExtrapolationDistance: Double,
        clusterRadius: Double,
        repeatPassMinimumInterval: TimeInterval,
        maximumClusters: Int,
        maximumMeasurements: Int,
        hapticRefractoryInterval: TimeInterval
    ) {
        self.enterZScore = enterZScore
        self.exitZScore = exitZScore
        self.absoluteFloorMicrotesla = absoluteFloorMicrotesla
        self.exitFloorFraction = exitFloorFraction
        self.persistenceRequired = persistenceRequired
        self.persistenceWindow = persistenceWindow
        self.smoothingWindow = smoothingWindow
        self.minimumSigma = minimumSigma
        self.baselineTimeConstant = baselineTimeConstant
        self.baselineUpdateMaxZScore = baselineUpdateMaxZScore
        self.gradientLookback = gradientLookback
        self.refractoryInterval = refractoryInterval
        self.calibrationMinimumDuration = calibrationMinimumDuration
        self.calibrationMinimumSamples = calibrationMinimumSamples
        self.calibrationMaximumSigma = calibrationMaximumSigma
        self.calibrationMaximumRange = calibrationMaximumRange
        self.timestampTolerance = timestampTolerance
        self.maximumScanSpeed = maximumScanSpeed
        self.minimumWallDistance = minimumWallDistance
        self.maximumWallDistance = maximumWallDistance
        self.maximumExtrapolationDistance = maximumExtrapolationDistance
        self.clusterRadius = clusterRadius
        self.repeatPassMinimumInterval = repeatPassMinimumInterval
        self.maximumClusters = maximumClusters
        self.maximumMeasurements = maximumMeasurements
        self.hapticRefractoryInterval = hapticRefractoryInterval
    }
}

import Foundation

/// Which way the field moved relative to baseline.
///
/// Both directions matter: ferrous material can concentrate the local field or
/// shield it, so a negative deviation is as real a measurement as a positive one.
enum AnomalyPolarity: String, Codable, Sendable, CaseIterable {
    case positive
    case negative

    var displayName: String {
        switch self {
        case .positive: return "Field increase"
        case .negative: return "Field decrease"
        }
    }

    var symbol: String {
        switch self {
        case .positive: return "arrow.up"
        case .negative: return "arrow.down"
        }
    }
}

/// A statistically significant, persistent change in the measured field.
///
/// This is deliberately *not* a claim about what caused the change. It carries
/// numbers and quality metadata and nothing else; nothing in the type system or
/// the UI can turn it into a screw, a wire, a stud or a pipe.
struct AnomalyCandidate: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    /// Monotonic timestamp of the sample that produced the candidate.
    var timestamp: TimeInterval
    /// The originating sample.
    var sample: MagneticFieldSample
    /// Median-smoothed magnitude at the moment of detection, µT.
    var smoothedMagnitude: Double
    /// Slow baseline in force at the moment of detection, µT.
    var baseline: Double
    /// Signed deviation from baseline, µT.
    var delta: Double
    /// `abs(delta) / sigma`.
    var robustZScore: Double
    /// Rate of change of the smoothed magnitude, µT per second.
    var gradient: Double
    /// How many of the last `persistenceWindow` samples exceeded threshold.
    var persistence: Int
    /// Sigma in force at detection, µT.
    var sigma: Double

    var polarity: AnomalyPolarity { delta >= 0 ? .positive : .negative }

    /// Normalised strength in `0...1`, used only for rendering intensity and
    /// ordering. Not a probability and not a confidence.
    ///
    /// Blends how far past the z-threshold the reading is with how far past the
    /// absolute floor it is, so a reading that is only statistically large
    /// (quiet environment) does not outrank one that is also physically large.
    func score(configuration: DetectorConfiguration) -> Double {
        let zHeadroom = max(0, robustZScore - configuration.enterZScore)
        let zTerm = zHeadroom / max(configuration.enterZScore, 0.001)
        let magnitudeTerm = abs(delta) / max(configuration.absoluteFloorMicrotesla * 4, 0.001)
        let blended = 0.35 + 0.35 * min(1, zTerm) + 0.30 * min(1, magnitudeTerm)
        return min(1, max(0, blended))
    }
}

/// What the detector is currently doing. Exposed for diagnostics and for the
/// scan HUD's state readout.
enum DetectorState: String, Codable, Sendable, CaseIterable {
    /// No baseline yet.
    case uncalibrated
    /// Baseline established, field quiet.
    case idle
    /// Threshold exceeded but not yet persistent enough to emit.
    case arming
    /// An anomaly event is in progress.
    case active
    /// Recently emitted; suppressing further emissions for this peak.
    case refractory

    var displayName: String {
        switch self {
        case .uncalibrated: return "Not calibrated"
        case .idle: return "Baseline steady"
        case .arming: return "Change detected"
        case .active: return "Anomaly"
        case .refractory: return "Settling"
        }
    }
}

/// Everything the detector produced for one sample.
struct DetectorOutput: Sendable, Equatable {
    var sample: MagneticFieldSample
    var smoothedMagnitude: Double
    var baseline: Double
    var sigma: Double
    var delta: Double
    var robustZScore: Double
    var gradient: Double
    var persistence: Int
    var state: DetectorState
    /// Non-nil only when a new candidate was emitted for this sample.
    var candidate: AnomalyCandidate?
}

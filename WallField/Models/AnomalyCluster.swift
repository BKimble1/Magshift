import Foundation

/// How much repeated evidence a cluster has.
///
/// This describes the *measurement*, never the cause. A cluster is "repeated"
/// when the same place on the wall produced an accepted reading on more than one
/// pass; that is all it means.
enum ClusterConfidence: String, Codable, Sendable, CaseIterable {
    /// Seen on one pass only, regardless of how large the reading was.
    case unconfirmed
    /// Measured again on a later pass with acceptable quality both times.
    case repeated

    var displayName: String {
        switch self {
        case .unconfirmed: return "Unconfirmed"
        case .repeated: return "Repeated"
        }
    }

    var explanation: String {
        switch self {
        case .unconfirmed: return SafetyCopy.unconfirmedExplanation
        case .repeated: return SafetyCopy.repeatedExplanation
        }
    }

    /// A non-colour cue, so state is never conveyed by colour alone.
    var symbolName: String {
        switch self {
        case .unconfirmed: return "circle.dashed"
        case .repeated: return "circle.grid.cross.fill"
        }
    }
}

/// Coarse strength band used for rendering and for the legend.
///
/// Bands are about the size of the measured change, not about what produced it.
enum AnomalyStrengthBand: String, Codable, Sendable, CaseIterable {
    case low
    case moderate
    case strong

    static func band(forScore score: Double) -> AnomalyStrengthBand {
        switch score {
        case ..<0.5: return .low
        case ..<0.75: return .moderate
        default: return .strong
        }
    }

    var displayName: String {
        switch self {
        case .low: return "Small change"
        case .moderate: return "Moderate change"
        case .strong: return "Large change"
        }
    }

    /// Non-colour cue used alongside colour in the AR view and the 2D map.
    var symbolName: String {
        switch self {
        case .low: return "circle"
        case .moderate: return "circle.lefthalf.filled"
        case .strong: return "circle.fill"
        }
    }
}

/// A spatially merged group of accepted candidates at one place on the wall.
///
/// Clustering exists so that one physical region produces one marker, however
/// many samples pass over it. Without it, a 50 Hz sensor stream would leak one
/// entity per sample into the RealityKit scene.
struct AnomalyCluster: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    /// Score-weighted centroid in wall space, metres.
    var wallPoint: WallPoint
    /// Position in the locked plane anchor's local space, used for rendering so
    /// markers follow the anchor as ARKit refines it.
    var anchorLocalPosition: Vector3
    /// Position in world space at the time of the most recent contribution.
    var worldPosition: Vector3
    /// Signed deviation of the strongest contributing sample, µT.
    var peakDelta: Double
    /// Robust z-score of the strongest contributing sample.
    var peakZScore: Double
    /// Highest normalised score among contributors, `0...1`.
    var peakScore: Double
    /// Sum of contributor scores; the weighting used for the centroid.
    var totalWeight: Double
    /// Number of accepted candidates merged into this cluster.
    var sampleCount: Int
    /// Indices of the scan passes that contributed.
    var passIndices: [Int]
    var firstSeen: Date
    var lastSeen: Date
    /// Monotonic time of the most recent contribution, used for the repeat-pass rule.
    var lastSeenMonotonic: TimeInterval
    /// Best spatial quality among contributors.
    var bestRaycastQuality: RaycastQuality
    /// Largest sensor-to-pose timing error among contributors, seconds.
    var worstTimingError: TimeInterval
    var polarity: AnomalyPolarity

    var confidence: ClusterConfidence {
        passIndices.count >= 2 ? .repeated : .unconfirmed
    }

    var strengthBand: AnomalyStrengthBand {
        AnomalyStrengthBand.band(forScore: peakScore)
    }

    var passCount: Int { passIndices.count }

    /// The only label the app applies to a cluster.
    var label: String { SafetyCopy.anomalyLabel }

    /// Accessibility description, colour-independent and free of object claims.
    var accessibilityDescription: String {
        "\(SafetyCopy.anomalyLabel). \(strengthBand.displayName). \(confidence.displayName). "
            + "Peak change \(Format.signedMicrotesla(peakDelta)). "
            + "\(sampleCount) samples across \(passCount) \(passCount == 1 ? "pass" : "passes")."
    }

    static func make(
        id: UUID = UUID(),
        candidate: AnomalyCandidate,
        score: Double,
        wallPoint: WallPoint,
        anchorLocalPosition: Vector3,
        worldPosition: Vector3,
        raycastQuality: RaycastQuality,
        timingError: TimeInterval,
        passIndex: Int,
        date: Date
    ) -> AnomalyCluster {
        AnomalyCluster(
            id: id,
            wallPoint: wallPoint,
            anchorLocalPosition: anchorLocalPosition,
            worldPosition: worldPosition,
            peakDelta: candidate.delta,
            peakZScore: candidate.robustZScore,
            peakScore: score,
            totalWeight: max(score, 0.0001),
            sampleCount: 1,
            passIndices: [passIndex],
            firstSeen: date,
            lastSeen: date,
            lastSeenMonotonic: candidate.timestamp,
            bestRaycastQuality: raycastQuality,
            worstTimingError: timingError,
            polarity: candidate.polarity
        )
    }
}

import Foundation

/// Mirrors `ARCamera.TrackingState` without importing ARKit, so quality gating
/// stays pure and unit testable.
enum TrackingQuality: Codable, Sendable, Hashable {
    case notAvailable
    case limited(LimitedReason)
    case normal

    enum LimitedReason: String, Codable, Sendable, Hashable, CaseIterable {
        case initializing
        case excessiveMotion
        case insufficientFeatures
        case relocalizing
        case unknown
    }

    /// Only `.normal` permits placing a marker.
    var permitsPlacement: Bool { self == .normal }

    var displayName: String {
        switch self {
        case .notAvailable: return "Tracking unavailable"
        case .normal: return "Tracking normal"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Starting up"
            case .excessiveMotion: return "Moving too fast"
            case .insufficientFeatures: return "Not enough detail"
            case .relocalizing: return "Recovering tracking"
            case .unknown: return "Tracking limited"
            }
        }
    }

    /// Plain-language instruction for the user.
    var recoveryInstruction: String? {
        switch self {
        case .normal:
            return nil
        case .notAvailable:
            return "Point the camera at the wall and hold steady."
        case .limited(let reason):
            switch reason {
            case .initializing: return "Move the phone slowly to let the camera map the wall."
            case .excessiveMotion: return "Move more slowly."
            case .insufficientFeatures: return "Improve lighting, or aim at a part of the wall with more texture."
            case .relocalizing: return "Return to where you were scanning and hold steady."
            case .unknown: return "Hold the phone steady."
            }
        }
    }
}

/// How a spatial position was obtained from the AR raycast.
enum RaycastQuality: String, Codable, Sendable, CaseIterable, Comparable {
    /// The ray hit the locked plane's actual detected geometry. Full quality.
    case planeGeometry

    /// The ray missed the detected geometry but hit the locked plane's infinite
    /// extension within a small bounded margin. Accepted, but recorded and
    /// rendered as lower spatial quality.
    case extrapolatedPlane

    /// No credible intersection with the locked wall. Never anchors a marker.
    case none

    private var rank: Int {
        switch self {
        case .none: return 0
        case .extrapolatedPlane: return 1
        case .planeGeometry: return 2
        }
    }

    static func < (lhs: RaycastQuality, rhs: RaycastQuality) -> Bool { lhs.rank < rhs.rank }

    var permitsPlacement: Bool { self != .none }

    var displayName: String {
        switch self {
        case .planeGeometry: return "On mapped wall"
        case .extrapolatedPlane: return "Just past mapped edge"
        case .none: return "Not on the selected wall"
        }
    }
}

/// A specific, actionable reason that data was rejected or downgraded.
///
/// Every rejection the user can see maps to one of these; the scan screen never
/// says "poor quality" without naming which condition failed.
enum QualityReason: String, Codable, Sendable, Hashable, CaseIterable {
    case magnetometerUnavailable
    case calibrationAccuracyLow
    case baselineNotEstablished
    case wallNotLocked
    case trackingNotNormal
    case noWallIntersection
    case extrapolatedIntersection
    case timingMismatch
    case sampleTimingUnstable
    case movingTooFast
    case tooCloseToWall
    case tooFarFromWall
    case insufficientPersistence
    case reducedQualitySource
    case clusterLimitReached

    /// Short instruction shown on the scan HUD.
    var guidance: String {
        switch self {
        case .magnetometerUnavailable: return "Magnetic data unavailable"
        case .calibrationAccuracyLow: return "Magnetic calibration needed"
        case .baselineNotEstablished: return "Calibrate the field first"
        case .wallNotLocked: return "Select and lock a wall"
        case .trackingNotNormal: return "Improve lighting"
        case .noWallIntersection: return "Point at the selected wall"
        case .extrapolatedIntersection: return "Aim inside the mapped area"
        case .timingMismatch: return "Hold the phone steady"
        case .sampleTimingUnstable: return "Sensor data is stalling"
        case .movingTooFast: return "Move more slowly"
        case .tooCloseToWall: return "Back off slightly from the wall"
        case .tooFarFromWall: return "Move closer to the wall"
        case .insufficientPersistence: return "Hold over the spot a moment longer"
        case .reducedQualitySource: return "Reduced-quality sensor data"
        case .clusterLimitReached: return "Maximum markers reached"
        }
    }

    /// Longer explanation used in the review summary and accessibility labels.
    var explanation: String {
        switch self {
        case .magnetometerUnavailable:
            return "Core Motion is not delivering magnetic-field data on this device."
        case .calibrationAccuracyLow:
            return "The reported magnetic calibration accuracy is below the level required to trust a reading."
        case .baselineNotEstablished:
            return "A quiet baseline has not been collected yet, so there is nothing to compare against."
        case .wallNotLocked:
            return "No wall has been selected and locked, so readings cannot be given a position."
        case .trackingNotNormal:
            return "ARKit world tracking is not in its normal state, so positions would be unreliable."
        case .noWallIntersection:
            return "The crosshair is not pointing at the locked wall."
        case .extrapolatedIntersection:
            return "The crosshair is just past the mapped edge of the wall; the position is extrapolated."
        case .timingMismatch:
            return "No camera pose was recorded close enough in time to this reading to place it accurately."
        case .sampleTimingUnstable:
            return "Sensor samples are arriving irregularly or too slowly to be trusted."
        case .movingTooFast:
            return "The phone is moving faster than the scan technique this app is calibrated for."
        case .tooCloseToWall:
            return "The phone is closer to the wall than the working range."
        case .tooFarFromWall:
            return "The phone is further from the wall than the working range; the field falls off quickly with distance."
        case .insufficientPersistence:
            return "Only one or two samples showed the change; a single sample is not enough evidence."
        case .reducedQualitySource:
            return "Only raw, uncalibrated magnetometer data is available. It is shown for diagnostics but cannot anchor a marker."
        case .clusterLimitReached:
            return "This scan already holds the maximum number of markers."
        }
    }

    /// Blocking reasons stop placement entirely; advisory reasons only downgrade
    /// quality metadata.
    var isBlocking: Bool {
        switch self {
        case .extrapolatedIntersection:
            return false
        default:
            return true
        }
    }
}

/// The outcome of evaluating every scan-quality gate for one candidate.
struct ScanQualityVerdict: Sendable, Equatable {
    var blocking: [QualityReason]
    var advisory: [QualityReason]

    var accepts: Bool { blocking.isEmpty }

    /// The single reason to surface on the HUD, chosen by severity order so the
    /// user is told the most fundamental problem first.
    var primaryReason: QualityReason? {
        let priority: [QualityReason] = [
            .magnetometerUnavailable,
            .sampleTimingUnstable,
            .calibrationAccuracyLow,
            .baselineNotEstablished,
            .wallNotLocked,
            .trackingNotNormal,
            .noWallIntersection,
            .movingTooFast,
            .tooFarFromWall,
            .tooCloseToWall,
            .timingMismatch,
            .insufficientPersistence,
            .clusterLimitReached,
            .reducedQualitySource,
        ]
        for reason in priority where blocking.contains(reason) { return reason }
        return blocking.first ?? advisory.first
    }

    static let accepted = ScanQualityVerdict(blocking: [], advisory: [])
}

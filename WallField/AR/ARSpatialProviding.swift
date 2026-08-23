import Foundation
import simd

/// A vertical plane ARKit has detected, reduced to plain values.
///
/// ARKit objects never cross a concurrency boundary in this app. The session
/// delegate runs off the main actor, so it converts each `ARPlaneAnchor` into
/// this `Sendable` snapshot -- including a copy of the boundary polygon -- and
/// sends that instead.
struct DetectedWall: Sendable, Equatable, Identifiable {
    var id: UUID
    /// Anchor transform in world space.
    var transform: simd_float4x4
    /// Plane centre in the anchor's local space.
    var center: SIMD3<Float>
    /// Plane extent along the anchor's local X and Z axes, metres.
    var extentX: Float
    var extentZ: Float
    /// Boundary polygon in the anchor's local space, if ARKit provided one.
    var boundary: [SIMD3<Float>]

    var area: Float { extentX * extentZ }

    /// Whether the plane is big enough to be worth offering as a scan surface.
    /// A 30 cm square is about the smallest region a slow hand pass can cover
    /// meaningfully.
    var isUsableAsWall: Bool { extentX >= 0.3 && extentZ >= 0.3 }
}

/// The wall the user selected, with the coordinate frame captured at lock time.
struct LockedWall: Sendable, Equatable {
    var id: UUID
    var frame: WallFrame
    /// Anchor transform at lock time.
    var anchorTransform: simd_float4x4
    var extentX: Float
    var extentZ: Float
    /// `+1` when the anchor's local +Y points the same way as `frame.normal`,
    /// `-1` otherwise. Used to push rendered markers off the wall towards the
    /// viewer rather than into it.
    var normalSign: Float

    var metadata: WallMetadata {
        WallMetadata(
            anchorIdentifier: id,
            frame: frame,
            extentWidth: Double(extentX),
            extentHeight: Double(extentZ),
            coveredBounds: nil
        )
    }
}

/// Why an AR session stopped being usable.
enum ARSessionProblem: Sendable, Equatable {
    case unsupportedDevice
    case cameraAccessDenied
    case cameraAccessRestricted
    case sessionFailed(String)
    case interrupted
    case relocalizationFailed

    var headline: String {
        switch self {
        case .unsupportedDevice: return "This iPhone cannot run AR wall mapping"
        case .cameraAccessDenied: return "Camera access is off"
        case .cameraAccessRestricted: return "Camera access is restricted"
        case .sessionFailed: return "The AR session stopped"
        case .interrupted: return "Scanning paused"
        case .relocalizationFailed: return "Could not find the wall again"
        }
    }

    var detail: String {
        switch self {
        case .unsupportedDevice:
            return "\(Branding.productName) needs ARKit world tracking, which this device does not provide."
        case .cameraAccessDenied:
            return "\(Branding.productName) needs the camera to recognise a wall and place readings on it. You can turn camera access on in Settings."
        case .cameraAccessRestricted:
            return "Camera access is restricted on this device, so a scan is not possible."
        case .sessionFailed(let message):
            return message
        case .interrupted:
            return "The camera was interrupted. Point it back at the wall to continue."
        case .relocalizationFailed:
            return "Tracking was lost and could not be recovered. Start a new scan rather than trusting the old positions."
        }
    }

    /// Whether the problem is recoverable in place, or requires a fresh scan.
    var isRecoverable: Bool {
        switch self {
        case .interrupted: return true
        case .unsupportedDevice, .cameraAccessDenied, .cameraAccessRestricted,
             .sessionFailed, .relocalizationFailed:
            return false
        }
    }
}

/// The AR capabilities the scan flow depends on, behind a protocol so the whole
/// flow can run on deterministic simulated data in the Simulator and in UI tests.
@MainActor
protocol ARSpatialProviding: AnyObject {
    var trackingQuality: TrackingQuality { get }
    var detectedWalls: [DetectedWall] { get }
    var lockedWall: LockedWall? { get }
    /// The crosshair's current intersection with the locked wall, if any.
    var currentHit: WallHit? { get }
    var isRunning: Bool { get }
    var problem: ARSessionProblem? { get }
    /// Whether the translucent wall overlay is drawn.
    var isWallOverlayVisible: Bool { get set }
    /// Newest recorded pose sample.
    var newestSpatialSample: SpatialSample? { get }

    func start()
    func pause()
    func resume()
    /// Drops all anchors and starts world tracking again from scratch.
    func resetTracking()
    func stop()

    /// Locks the given detected wall. Returns `false` when a usable wall frame
    /// could not be derived, in which case nothing is locked.
    func lockWall(id: UUID) -> Bool
    func unlockWall()

    /// Nearest recorded pose to `timestamp` within `tolerance`.
    func spatialMatch(for timestamp: TimeInterval, tolerance: TimeInterval) -> SpatialMatch?

    /// Creates or updates the rendered marker for a cluster.
    func renderCluster(_ cluster: AnomalyCluster)
    func removeClusterMarker(id: UUID)
    func removeAllClusterMarkers()
}

import ARKit
import Foundation

/// Something the AR session reported.
enum ARSessionEvent: Sendable {
    case wallsChanged([DetectedWall])
    case wallsRemoved([UUID])
    case trackingChanged(TrackingQuality)
    case failed(String)
    case interrupted
    case interruptionEnded
    /// ARKit asked whether it should try to relocalise after an interruption and
    /// was told not to. See `sessionShouldAttemptRelocalization(_:)`.
    case relocalizationDeclined
}

/// Bridges `ARSessionDelegate` -- which is called on ARKit's own queue -- onto an
/// `AsyncStream` the main actor consumes.
///
/// `@unchecked Sendable` is justified and narrow: the only stored property is an
/// immutable `AsyncStream.Continuation`, which is itself `Sendable`. The
/// conformance cannot be checked automatically only because the class must
/// inherit from `NSObject` to be an `ARSessionDelegate`.
///
/// Crucially, no ARKit object ever escapes these callbacks. Each delegate method
/// converts what it needs into plain value types before yielding, so no `ARFrame`
/// is retained (retaining frames stalls ARKit) and no non-`Sendable` reference
/// crosses to another actor.
final class ARSessionEventRelay: NSObject, ARSessionDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<ARSessionEvent>.Continuation

    init(continuation: AsyncStream<ARSessionEvent>.Continuation) {
        self.continuation = continuation
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        emitWalls(from: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        emitWalls(from: anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let identifiers = anchors.compactMap { ($0 as? ARPlaneAnchor)?.identifier }
        guard !identifiers.isEmpty else { return }
        continuation.yield(.wallsRemoved(identifiers))
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        continuation.yield(.trackingChanged(TrackingQuality(camera.trackingState)))
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        continuation.yield(.failed(Self.describe(error)))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        continuation.yield(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        continuation.yield(.interruptionEnded)
    }

    /// Returning `false` means ARKit will not silently re-place stale content
    /// after tracking is lost. A scan whose world origin has moved cannot have
    /// its old wall coordinates trusted.
    ///
    /// ARKit calls this *after an interruption ends*; it is a question, not a
    /// report that relocalisation failed. The distinction matters: the answer is
    /// always "no", but whether that ends the scan depends on whether there was
    /// anything to invalidate, which only the controller knows. So the event
    /// says what happened -- relocalisation was declined -- and
    /// `ARSessionController` decides what it means.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        continuation.yield(.relocalizationDeclined)
        return false
    }

    // MARK: - Conversion

    private func emitWalls(from anchors: [ARAnchor]) {
        let walls = anchors.compactMap { anchor -> DetectedWall? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
            return DetectedWall(
                id: plane.identifier,
                transform: plane.transform,
                center: plane.center,
                extentX: plane.planeExtent.width,
                extentZ: plane.planeExtent.height,
                boundary: plane.geometry.boundaryVertices
            )
        }
        guard !walls.isEmpty else { return }
        continuation.yield(.wallsChanged(walls))
    }

    private static func describe(_ error: any Error) -> String {
        guard let arError = error as? ARError else { return error.localizedDescription }
        switch arError.code {
        case .cameraUnauthorized:
            return "Camera access is off for \(Branding.productName)."
        case .unsupportedConfiguration:
            return "This device does not support the AR configuration \(Branding.productName) needs."
        case .sensorUnavailable, .sensorFailed:
            return "A sensor the AR session needs is unavailable."
        case .worldTrackingFailed:
            return "World tracking failed. Improve lighting and try again."
        default:
            return arError.localizedDescription
        }
    }
}

extension TrackingQuality {
    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .notAvailable:
            self = .notAvailable
        case .normal:
            self = .normal
        case .limited(let reason):
            switch reason {
            case .initializing: self = .limited(.initializing)
            case .excessiveMotion: self = .limited(.excessiveMotion)
            case .insufficientFeatures: self = .limited(.insufficientFeatures)
            case .relocalizing: self = .limited(.relocalizing)
            @unknown default: self = .limited(.unknown)
            }
        }
    }
}

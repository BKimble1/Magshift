import ARKit
import AVFoundation
import Foundation

/// What this particular device and this particular install can actually do.
///
/// Every capability is *queried*, never assumed. The app has to behave correctly
/// on a device without ARKit world tracking, without a magnetometer, and with
/// camera access denied, and it must never present a scanning UI it cannot back
/// with real data.
struct DeviceCapabilities: Sendable, Equatable {
    var supportsWorldTracking: Bool
    var supportsVerticalPlaneDetection: Bool
    var supportsSceneDepth: Bool
    var supportsSceneReconstruction: Bool
    var cameraAuthorization: CameraAuthorization

    enum CameraAuthorization: String, Sendable, Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted

        var isUsable: Bool { self == .authorized }
    }

    /// True when a live scan is possible at all. Simulated mode bypasses this.
    var canRunLiveScan: Bool {
        supportsWorldTracking && supportsVerticalPlaneDetection && cameraAuthorization.isUsable
    }

    static func current() -> DeviceCapabilities {
        let worldTracking = ARWorldTrackingConfiguration.isSupported
        return DeviceCapabilities(
            supportsWorldTracking: worldTracking,
            // Vertical plane detection is available wherever world tracking is,
            // on every iOS 18 capable device. It is still expressed as its own
            // flag so the scan flow reads a capability rather than a constant.
            supportsVerticalPlaneDetection: worldTracking,
            supportsSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            supportsSceneReconstruction: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
            cameraAuthorization: readCameraAuthorization()
        )
    }

    /// Capabilities reported while running on simulated data, so the Simulator
    /// can exercise the full flow.
    static func simulated() -> DeviceCapabilities {
        DeviceCapabilities(
            supportsWorldTracking: true,
            supportsVerticalPlaneDetection: true,
            supportsSceneDepth: false,
            supportsSceneReconstruction: false,
            cameraAuthorization: .authorized
        )
    }

    static func readCameraAuthorization() -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Asks for camera access and reports what the user decided.
    ///
    /// Returns immediately with the current status when the decision has already
    /// been made -- `requestAccess` never re-prompts, and a caller that treated
    /// its `false` as "just denied" would misreport a restriction.
    ///
    /// Access is requested in exactly one place: the first-run screen, beside the
    /// sentence explaining why it is needed. ARKit would otherwise raise the
    /// prompt itself when a session starts, which puts a system alert in front of
    /// a user who has just tapped Start scanning and is holding the phone at a
    /// wall. Asking once, up front, on a screen that is standing still, is both
    /// clearer and less likely to be refused by reflex.
    static func requestCameraAccess() async -> CameraAuthorization {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            return readCameraAuthorization()
        }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return readCameraAuthorization()
    }
}

/// Non-identifying device and OS metadata stored with a scan so results can be
/// compared across models during validation.
///
/// Deliberately excludes any persistent identifier. `identifierForVendor` is not
/// read, and no advertising identifier is requested.
struct DeviceMetadata: Codable, Sendable, Hashable {
    var model: String
    var systemName: String
    var systemVersion: String
    var supportsSceneDepth: Bool
    var supportsSceneReconstruction: Bool

    static func current(capabilities: DeviceCapabilities) -> DeviceMetadata {
        DeviceMetadata(
            model: hardwareModelIdentifier(),
            systemName: "iOS",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            supportsSceneDepth: capabilities.supportsSceneDepth,
            supportsSceneReconstruction: capabilities.supportsSceneReconstruction
        )
    }

    /// e.g. `iPhone16,1`. This is a model identifier shared by every unit of that
    /// model; it identifies hardware, not a person or a device.
    static func hardwareModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let characters = mirror.children.compactMap { child -> Character? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return Character(UnicodeScalar(UInt8(bitPattern: value)))
        }
        let identifier = String(characters)
        return identifier.isEmpty ? "unknown" : identifier
    }
}

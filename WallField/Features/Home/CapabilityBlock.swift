import Foundation

/// A reason the device cannot start a live scan, with the recovery the user has.
///
/// Evaluated in one place so Home and the scan flow present the same explanation
/// rather than each inventing wording for the same condition.
struct CapabilityBlock: Equatable {
    var title: String
    var message: String
    var systemImage: String
    var offersSettings: Bool

    static func evaluate(
        _ capabilities: DeviceCapabilities,
        runtimeMode: RuntimeMode
    ) -> CapabilityBlock? {
        // Simulated data deliberately bypasses hardware checks: that is the whole
        // point of it, and every screen it drives is labelled as simulated.
        //
        // A denied camera authorization is not a hardware fact, though. Simulated
        // capabilities always report the camera as authorized, so the only way it
        // reads as denied here is `-WallFieldSimulateCameraDenied`, which exists
        // precisely so the permission-denied recovery path can be exercised.
        // Returning early on it would make that launch argument do nothing.
        if runtimeMode.isSimulated, capabilities.cameraAuthorization.isUsable { return nil }

        if !capabilities.supportsWorldTracking {
            return CapabilityBlock(
                title: "AR wall mapping is not available",
                message: """
                    \(Branding.productName) needs ARKit world tracking to recognise a wall and place \
                    readings on it. This iPhone does not provide it, so scanning is not possible. \
                    Sensor diagnostics still work and can record raw magnetic-field data.
                    """,
                systemImage: "iphone.slash",
                offersSettings: false
            )
        }

        switch capabilities.cameraAuthorization {
        case .denied:
            return CapabilityBlock(
                title: "Camera access is off",
                message: """
                    \(Branding.productName) uses the camera to recognise a wall and place magnetic-field \
                    visualizations on it. Turn on camera access in Settings to scan.
                    """,
                systemImage: "camera.fill",
                offersSettings: true
            )
        case .restricted:
            return CapabilityBlock(
                title: "Camera access is restricted",
                message: """
                    Camera access is restricted on this device, so a scan is not possible. Sensor \
                    diagnostics still work.
                    """,
                systemImage: "lock.fill",
                offersSettings: false
            )
        case .authorized, .notDetermined:
            // Not determined is not a block: the system prompt is presented when
            // the scan starts, which is the moment the reason for it is obvious.
            return nil
        }
    }
}

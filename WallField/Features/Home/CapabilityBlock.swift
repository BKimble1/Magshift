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
        // Simulated data deliberately bypasses the *hardware* checks: that is the
        // whole point of it, and every screen it drives is labelled as simulated.
        //
        // Camera authorization is deliberately not bypassed. It is a permission,
        // not a capability, and `DeviceCapabilities.simulated()` reports
        // `.authorized`, so a refusal reaching here in simulated mode can only
        // have been set on purpose -- which is exactly what
        // `-WallFieldSimulateCameraDenied` does so the recovery path can be
        // driven by a UI test.
        if !runtimeMode.isSimulated, !capabilities.supportsWorldTracking {
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

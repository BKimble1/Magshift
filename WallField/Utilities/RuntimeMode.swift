import Foundation

/// Whether the app is running on real sensors or on deterministic simulated data.
///
/// Simulated data exists because ARKit and the magnetometer are unavailable in
/// the iOS Simulator and in automated UI tests. It is a development and testing
/// facility only:
///
/// * a Release build has no path into it at all: `resolve()` returns `.live`
///   unconditionally under `#if !DEBUG`, and every switch into simulated mode
///   is behind the same guard, so no Release build can select it;
/// * in Debug builds it must be requested explicitly, either by the
///   `-WallFieldDemoMode` launch argument or by the Developer section in
///   Settings;
/// * every screen that renders simulated data shows a persistent
///   "Simulated data" banner.
///
/// `RuntimeMode.current` is resolved once at launch and never changes for the
/// lifetime of the process, so no screen can be half-simulated.
enum RuntimeMode: String, Sendable {
    /// Real Core Motion and ARKit.
    case live
    /// Reproducible synthetic sensor and spatial data.
    case simulated

    static let demoLaunchArgument = "-WallFieldDemoMode"
    static let resetStateLaunchArgument = "-WallFieldResetState"

    /// Makes the app behave as though the user had refused camera access, so the
    /// permission-denied recovery path can be exercised by a UI test. Debug
    /// builds only; there is no way to reach it in a Release build.
    static let simulateCameraDeniedArgument = "-WallFieldSimulateCameraDenied"

    /// User-defaults key backing the Developer toggle in Settings.
    static let developerPreferenceKey = "wallfield.developer.simulatedData"

    /// Resolves the mode for this process.
    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) -> RuntimeMode {
        #if DEBUG
        if arguments.contains(demoLaunchArgument) { return .simulated }
        if defaults.bool(forKey: developerPreferenceKey) { return .simulated }
        return .live
        #else
        // Release builds have no path into simulated data at all.
        _ = arguments
        _ = defaults
        return .live
        #endif
    }

    /// Resolved once, at launch.
    static let current: RuntimeMode = resolve()

    var isSimulated: Bool { self == .simulated }

    /// Banner text shown on every screen driven by simulated data.
    static let simulatedBannerText = "Simulated data \u{2014} not a real measurement"

    /// Whether the Developer section should be offered in Settings at all.
    static var developerToolsAvailable: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Whether the camera-denied path should be simulated for a UI test.
    static func shouldSimulateCameraDenied(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        #if DEBUG
        return arguments.contains(simulateCameraDeniedArgument)
        #else
        _ = arguments
        return false
        #endif
    }

    /// UI tests pass `-WallFieldResetState` so each test starts from first launch.
    static func shouldResetPersistentState(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        #if DEBUG
        return arguments.contains(resetStateLaunchArgument)
        #else
        _ = arguments
        return false
        #endif
    }
}

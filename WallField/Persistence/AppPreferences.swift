import Foundation
import Observation

/// User preferences and the safety acknowledgement record.
///
/// Backed by `UserDefaults` because every value here is a small, non-sensitive
/// preference. Scans -- the only substantial data the app holds -- live in
/// Application Support behind `ScanStoring` instead.
///
/// # Acknowledgement versioning
///
/// Both the accepted version and the date are stored. When
/// `SafetyCopy.acknowledgementVersion` is raised because the safety wording
/// changed materially, `needsSafetyAcknowledgement` becomes true again and the
/// user is shown the revised statement before scanning. Previously accepted
/// versions are not treated as accepting new wording.
@MainActor
@Observable
final class AppPreferences {

    private enum Key {
        static let sensitivity = "wallfield.sensitivity"
        static let haptics = "wallfield.haptics"
        static let sound = "wallfield.sound"
        static let wallOverlay = "wallfield.wallOverlay"
        static let acknowledgementVersion = "wallfield.acknowledgement.version"
        static let acknowledgementDate = "wallfield.acknowledgement.date"
        static let hasCompletedOnboarding = "wallfield.onboarding.completed"
        static let scanCounter = "wallfield.scanCounter"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storedSensitivity = SensitivityPreset(
            rawValue: defaults.string(forKey: Key.sensitivity) ?? ""
        ) ?? .medium
        self.storedHapticsEnabled = defaults.object(forKey: Key.haptics) as? Bool ?? true
        // Sound is off by default. A scan is often performed in someone else's
        // home or workplace, and an app that starts beeping is unwelcome.
        self.storedSoundEnabled = defaults.object(forKey: Key.sound) as? Bool ?? false
        self.storedWallOverlayVisible = defaults.object(forKey: Key.wallOverlay) as? Bool ?? true
        self.acknowledgedVersion = defaults.integer(forKey: Key.acknowledgementVersion)
        self.acknowledgedAt = defaults.object(forKey: Key.acknowledgementDate) as? Date
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.scanCounter = defaults.integer(forKey: Key.scanCounter)
    }

    // MARK: - Stored preferences

    // Each preference is a computed property over a tracked stored property, so
    // that writing it both updates observers and persists it. `@Observable` does
    // not support `didSet` on a tracked property, and a separate `save()` call
    // that a caller could forget is exactly the kind of thing that silently
    // stops working.

    private var storedSensitivity: SensitivityPreset
    var sensitivity: SensitivityPreset {
        get { storedSensitivity }
        set {
            storedSensitivity = newValue
            defaults.set(newValue.rawValue, forKey: Key.sensitivity)
        }
    }

    private var storedHapticsEnabled: Bool
    var hapticsEnabled: Bool {
        get { storedHapticsEnabled }
        set {
            storedHapticsEnabled = newValue
            defaults.set(newValue, forKey: Key.haptics)
        }
    }

    private var storedSoundEnabled: Bool
    var soundEnabled: Bool {
        get { storedSoundEnabled }
        set {
            storedSoundEnabled = newValue
            defaults.set(newValue, forKey: Key.sound)
        }
    }

    private var storedWallOverlayVisible: Bool
    var wallOverlayVisible: Bool {
        get { storedWallOverlayVisible }
        set {
            storedWallOverlayVisible = newValue
            defaults.set(newValue, forKey: Key.wallOverlay)
        }
    }

    private(set) var hasCompletedOnboarding: Bool

    private(set) var acknowledgedVersion: Int
    private(set) var acknowledgedAt: Date?

    /// Monotonically increasing counter used to name new scans.
    private(set) var scanCounter: Int

    // MARK: - Derived

    /// True until the user accepts the *current* safety wording.
    var needsSafetyAcknowledgement: Bool {
        acknowledgedVersion < SafetyCopy.acknowledgementVersion
    }

    /// True when onboarding should be presented: either it was never completed,
    /// or the safety wording has changed since it was.
    var needsOnboarding: Bool {
        !hasCompletedOnboarding || needsSafetyAcknowledgement
    }

    /// Whether the user is being shown revised wording rather than seeing the
    /// app for the first time.
    var isReacknowledging: Bool {
        hasCompletedOnboarding && needsSafetyAcknowledgement
    }

    var detectorConfiguration: DetectorConfiguration {
        DetectorConfiguration.preset(sensitivity)
    }

    // MARK: - Mutations

    /// Records acceptance of the current safety statement.
    func recordSafetyAcknowledgement(at date: Date = Date()) {
        acknowledgedVersion = SafetyCopy.acknowledgementVersion
        acknowledgedAt = date
        hasCompletedOnboarding = true
        defaults.set(acknowledgedVersion, forKey: Key.acknowledgementVersion)
        defaults.set(date, forKey: Key.acknowledgementDate)
        defaults.set(true, forKey: Key.hasCompletedOnboarding)
    }

    /// The default name for the next scan.
    func nextScanName() -> String {
        "Wall scan \(scanCounter + 1)"
    }

    func incrementScanCounter() {
        scanCounter += 1
        defaults.set(scanCounter, forKey: Key.scanCounter)
    }

    /// Clears everything. Used by the developer tools and by
    /// `-WallFieldResetState` in UI tests so each test starts at first launch.
    func resetAll() {
        for key in [
            Key.sensitivity, Key.haptics, Key.sound, Key.wallOverlay,
            Key.acknowledgementVersion, Key.acknowledgementDate,
            Key.hasCompletedOnboarding, Key.scanCounter,
        ] {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: RuntimeMode.developerPreferenceKey)
        sensitivity = .medium
        hapticsEnabled = true
        soundEnabled = false
        wallOverlayVisible = true
        acknowledgedVersion = 0
        acknowledgedAt = nil
        hasCompletedOnboarding = false
        scanCounter = 0
    }
}

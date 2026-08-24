import SwiftUI

/// Layout and typography constants.
///
/// Sizes are expressed in points but every text style is a semantic
/// `Font.TextStyle`, so the whole interface scales with Dynamic Type rather than
/// being pinned to one size. Nothing in the app uses a fixed point size for body
/// text.
enum Theme {

    enum Spacing {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 6
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let extraLarge: CGFloat = 36
    }

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
    }

    /// Minimum tappable dimension. Controls sit over live camera imagery, where a
    /// missed tap is more than an annoyance, so nothing goes below this.
    static let minimumTouchTarget: CGFloat = 48

    /// Rate at which live readouts are republished. Sensor processing runs far
    /// faster; there is no point redrawing a number more often than a person can
    /// read it, and doing so costs battery and heat.
    static let readoutUpdatesPerSecond: Double = 10

    enum Typography {
        static var screenTitle: Font { .system(.largeTitle, design: .rounded, weight: .bold) }
        static var sectionTitle: Font { .system(.title3, design: .rounded, weight: .semibold) }
        static var cardTitle: Font { .system(.headline, design: .rounded) }
        static var body: Font { .system(.body) }
        static var caption: Font { .system(.caption) }
        /// Monospaced digits, so a changing readout does not jitter horizontally.
        static var readout: Font {
            .system(.title2, design: .rounded, weight: .semibold).monospacedDigit()
        }
        static var readoutSmall: Font {
            .system(.subheadline, design: .rounded, weight: .medium).monospacedDigit()
        }
    }

    /// Material used behind controls that sit over the camera feed.
    static var hudMaterial: Material { .ultraThinMaterial }
}

/// Accessibility identifiers used by UI tests.
///
/// Declared centrally, and applied to controls that exist for the user's benefit
/// anyway. No control exists solely to be testable, and no accessibility label
/// has been distorted to make an assertion easier.
enum A11y {
    static let onboardingContinue = "onboarding.continue"
    static let onboardingAcknowledgeToggle = "onboarding.acknowledge.toggle"
    static let onboardingAcceptButton = "onboarding.accept"
    static let onboardingAllowCamera = "onboarding.allowCamera"

    static let homeNewScan = "home.newScan"
    static let homeHistory = "home.history"
    static let homeDiagnostics = "home.diagnostics"
    static let homeSettings = "home.settings"
    static let homeHowItWorks = "home.howItWorks"
    static let homeSimulatedBanner = "home.simulatedBanner"
    static let safetyBanner = "safety.banner"

    static let prepChecklistContinue = "prep.continue"
    static let scannerLockWall = "scanner.lockWall"
    static let scannerCalibrate = "scanner.calibrate"
    static let scannerStart = "scanner.start"
    static let scannerPause = "scanner.pause"
    static let scannerResume = "scanner.resume"
    static let scannerNewPass = "scanner.newPass"
    static let scannerUndo = "scanner.undo"
    static let scannerReset = "scanner.reset"
    static let scannerConfirmReset = "scanner.confirmReset"
    static let scannerFinish = "scanner.finish"
    static let scannerSafety = "scanner.safety"
    static let scannerOverlayToggle = "scanner.overlayToggle"
    static let scannerStatus = "scanner.status"
    static let scannerClusterCount = "scanner.clusterCount"
    static let scannerSimulatedCanvas = "scanner.simulatedCanvas"

    static let reviewSave = "review.save"
    static let reviewDiscard = "review.discard"
    static let reviewName = "review.name"
    static let reviewNotes = "review.notes"
    static let reviewExport = "review.export"
    static let reviewClusterCount = "review.clusterCount"
    static let reviewNoAnomalies = "review.noAnomalies"

    static let historyList = "history.list"
    static let historyEmpty = "history.empty"
    static let historyDelete = "history.delete"
    static let historyConfirmDelete = "history.confirmDelete"

    static let safetyPage = "safety.page"
    static let safetyClose = "safety.close"

    static let diagnosticsStart = "diagnostics.start"
    static let diagnosticsStop = "diagnostics.stop"
    static let diagnosticsExport = "diagnostics.export"

    static let settingsSafety = "settings.safety"
    static let settingsSensitivity = "settings.sensitivity"
    static let settingsSimulatedData = "settings.simulatedData"

    static func cluster(_ index: Int) -> String { "cluster.\(index)" }
}

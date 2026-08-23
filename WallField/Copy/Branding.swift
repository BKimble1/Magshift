import Foundation

/// Single source of truth for the product's user-facing identity.
///
/// Every screen, export header and document string pulls its name from here so
/// the product can be renamed without touching feature code.
enum Branding {
    /// Display name shown to users.
    static let productName = "WallField"

    /// Legal owner of the app.
    static let organizationName = "Idlery Services LLC"

    /// The honest product category. This exact phrasing is used in onboarding,
    /// the App Store description and review notes.
    static let productCategory = "An experimental AR magnetic-field anomaly mapper for walls."

    /// One-line summary used on the home screen and in the share sheet.
    static let tagline = "Visualize changes in the magnetic field around your iPhone."

    /// Marketing version, read from the bundle so it can never drift from the build.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// Build number, read from the bundle.
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    static var versionDisplayString: String {
        "\(appVersion) (\(buildNumber))"
    }

    /// Support and privacy destinations.
    ///
    /// These are deliberately `nil` until Idlery Services LLC publishes them.
    /// `Docs/APP_STORE_PREP.md` lists them as blocking items for submission, and
    /// the Settings screen hides the corresponding rows while they are `nil`
    /// rather than shipping a dead control that opens nothing.
    static let supportURL: URL? = nil
    static let privacyPolicyURL: URL? = nil
}

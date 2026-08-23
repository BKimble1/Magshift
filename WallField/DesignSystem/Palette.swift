import SwiftUI
import UIKit

/// The app's colour palette, defined once so SwiftUI and RealityKit cannot drift
/// apart. The legend on the scan screen has to match the discs rendered in AR
/// exactly, and they are drawn by two different frameworks.
///
/// # Colour is never the only cue
///
/// Every state that uses colour also carries a shape, symbol or text difference:
/// strength bands have distinct SF Symbols, unconfirmed markers are rings while
/// repeated markers are filled with a bright centre, and both the legend and the
/// 2D map label states in words. See `Docs/ARCHITECTURE.md` -> "Accessibility".
///
/// # There is no green
///
/// The palette contains no success/safe colour by design. A quiet reading must
/// never be presented as an all-clear, so there is deliberately no green swatch
/// available to render one with.
enum Palette {

    // MARK: - Raw components

    private static let overlayBlueComponents = (r: 0.24, g: 0.55, b: 0.98)
    private static let lowComponents = (r: 0.36, g: 0.66, b: 0.94)
    private static let moderateComponents = (r: 0.96, g: 0.70, b: 0.20)
    private static let strongComponents = (r: 0.92, g: 0.30, b: 0.26)
    private static let confirmedCoreComponents = (r: 0.97, g: 0.97, b: 1.00)
    private static let markerVoidComponents = (r: 0.06, g: 0.08, b: 0.12)

    // MARK: - SwiftUI

    /// Translucent overlay drawn over a detected wall.
    static var wallOverlay: Color { color(overlayBlueComponents) }
    /// Smallest measured change.
    static var strengthLow: Color { color(lowComponents) }
    /// Moderate measured change.
    static var strengthModerate: Color { color(moderateComponents) }
    /// Largest measured change.
    static var strengthStrong: Color { color(strongComponents) }
    /// The bright centre that marks a repeated cluster.
    static var confirmedCore: Color { color(confirmedCoreComponents) }

    /// Accent used for primary actions.
    static var accent: Color { color(overlayBlueComponents) }

    /// Warning tint. Amber, never red, so a caution is not confused with a
    /// strong reading, and never green, so it is not confused with safety.
    static var caution: Color { color(moderateComponents) }

    static func color(forBand band: AnomalyStrengthBand) -> Color {
        switch band {
        case .low: return strengthLow
        case .moderate: return strengthModerate
        case .strong: return strengthStrong
        }
    }

    // MARK: - UIKit / RealityKit

    static func uiColor(forBand band: AnomalyStrengthBand) -> UIColor {
        switch band {
        case .low: return uiColor(lowComponents)
        case .moderate: return uiColor(moderateComponents)
        case .strong: return uiColor(strongComponents)
        }
    }

    static var wallOverlayUIColor: UIColor { uiColor(overlayBlueComponents) }
    static var confirmedCoreUIColor: UIColor { uiColor(confirmedCoreComponents) }
    static var markerVoidUIColor: UIColor { uiColor(markerVoidComponents) }

    // MARK: - Helpers

    private static func color(_ components: (r: Double, g: Double, b: Double)) -> Color {
        Color(red: components.r, green: components.g, blue: components.b)
    }

    private static func uiColor(_ components: (r: Double, g: Double, b: Double)) -> UIColor {
        UIColor(red: components.r, green: components.g, blue: components.b, alpha: 1)
    }
}

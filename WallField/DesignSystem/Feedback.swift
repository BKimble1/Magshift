import AudioToolbox
import Foundation
import UIKit

/// Haptic and audible feedback.
///
/// Both are throttled by the caller (`ClusterEngine` limits pulses per cluster)
/// and both respect the user's preferences. Sound is off by default.
///
/// The generator is prepared before a scan and released afterwards, so the
/// Taptic Engine is not held awake between scans.
@MainActor
final class FeedbackController {
    private var impactGenerator: UIImpactFeedbackGenerator?
    private var notificationGenerator: UINotificationFeedbackGenerator?

    var hapticsEnabled = true
    var soundEnabled = false

    /// System sound used to mark a new cluster. A short, neutral tick -- not an
    /// alarm. Nothing this app measures warrants an alarm.
    private static let markerSoundID: SystemSoundID = 1104

    /// Warms the Taptic Engine before a scan. Skipped when haptics are off, so
    /// the engine is not woken for a scan that will never pulse.
    func prepare() {
        guard hapticsEnabled else { return }
        impact().prepare()
        notification().prepare()
    }

    func release() {
        impactGenerator = nil
        notificationGenerator = nil
    }

    // The generators are created on demand rather than only in `prepare()`.
    // Haptics can be switched on from the scan HUD *after* a scan has started,
    // and `prepare()` will already have skipped them; without this the toggle
    // would appear to work and produce nothing for the rest of the scan.

    private func impact() -> UIImpactFeedbackGenerator {
        if let impactGenerator { return impactGenerator }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        impactGenerator = generator
        return generator
    }

    private func notification() -> UINotificationFeedbackGenerator {
        if let notificationGenerator { return notificationGenerator }
        let generator = UINotificationFeedbackGenerator()
        notificationGenerator = generator
        return generator
    }

    /// Fired when a new cluster appears.
    func newCluster() {
        if hapticsEnabled {
            let generator = impact()
            generator.impactOccurred(intensity: 0.9)
            generator.prepare()
        }
        if soundEnabled {
            AudioServicesPlaySystemSound(Self.markerSoundID)
        }
    }

    /// Fired when an existing cluster gains a repeated observation. Softer than
    /// a new cluster so the two are distinguishable without looking.
    func repeatedCluster() {
        guard hapticsEnabled else { return }
        let generator = impact()
        generator.impactOccurred(intensity: 0.5)
        generator.prepare()
    }

    /// Fired when a stage of the scan flow completes, such as a successful
    /// calibration.
    func stageCompleted() {
        guard hapticsEnabled else { return }
        let generator = notification()
        generator.notificationOccurred(.success)
        generator.prepare()
    }

    /// Fired when something was refused, such as a rejected calibration.
    func refused() {
        guard hapticsEnabled else { return }
        let generator = notification()
        generator.notificationOccurred(.warning)
        generator.prepare()
    }
}

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

    /// Warms the Taptic Engine ahead of a scan.
    func prepare() {
        _ = impact()
        _ = notification()
    }

    // The generators are created on demand rather than only in `prepare`, so
    // turning haptics on part-way through a scan works. Creating them eagerly at
    // launch instead would hold the Taptic Engine awake for users who never scan.

    private func impact() -> UIImpactFeedbackGenerator? {
        guard hapticsEnabled else { return nil }
        if let impactGenerator { return impactGenerator }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        impactGenerator = generator
        return generator
    }

    private func notification() -> UINotificationFeedbackGenerator? {
        guard hapticsEnabled else { return nil }
        if let notificationGenerator { return notificationGenerator }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        notificationGenerator = generator
        return generator
    }

    func release() {
        impactGenerator = nil
        notificationGenerator = nil
    }

    /// Fired when a new cluster appears.
    func newCluster() {
        if let generator = impact() {
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
        guard let generator = impact() else { return }
        generator.impactOccurred(intensity: 0.5)
        generator.prepare()
    }

    /// Fired when a stage of the scan flow completes, such as a successful
    /// calibration.
    func stageCompleted() {
        guard let generator = notification() else { return }
        generator.notificationOccurred(.success)
        generator.prepare()
    }

    /// Fired when something was refused, such as a rejected calibration.
    func refused() {
        guard let generator = notification() else { return }
        generator.notificationOccurred(.warning)
        generator.prepare()
    }
}

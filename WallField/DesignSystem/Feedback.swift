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

    func prepare() {
        guard hapticsEnabled else { return }
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.prepare()
        impactGenerator = impact
        let notification = UINotificationFeedbackGenerator()
        notification.prepare()
        notificationGenerator = notification
    }

    func release() {
        impactGenerator = nil
        notificationGenerator = nil
    }

    /// Fired when a new cluster appears.
    func newCluster() {
        if hapticsEnabled {
            impactGenerator?.impactOccurred(intensity: 0.9)
            impactGenerator?.prepare()
        }
        if soundEnabled {
            AudioServicesPlaySystemSound(Self.markerSoundID)
        }
    }

    /// Fired when an existing cluster gains a repeated observation. Softer than
    /// a new cluster so the two are distinguishable without looking.
    func repeatedCluster() {
        guard hapticsEnabled else { return }
        impactGenerator?.impactOccurred(intensity: 0.5)
        impactGenerator?.prepare()
    }

    /// Fired when a stage of the scan flow completes, such as a successful
    /// calibration.
    func stageCompleted() {
        guard hapticsEnabled else { return }
        notificationGenerator?.notificationOccurred(.success)
        notificationGenerator?.prepare()
    }

    /// Fired when something was refused, such as a rejected calibration.
    func refused() {
        guard hapticsEnabled else { return }
        notificationGenerator?.notificationOccurred(.warning)
        notificationGenerator?.prepare()
    }
}

import ARKit
import RealityKit
import SwiftUI

/// The thinnest possible SwiftUI wrapper around the controller's `ARView`.
///
/// It creates nothing and owns nothing: the `ARView` and the session belong to
/// `ARSessionController`, which outlives any particular view. That keeps AR
/// lifecycle out of SwiftUI's view-identity rules, where a harmless-looking
/// re-render could otherwise restart the session mid-scan.
struct ARViewContainer: UIViewRepresentable {
    let controller: ARSessionController
    /// Whether the ARKit coaching overlay should be offered.
    var showsCoaching: Bool

    func makeUIView(context: Context) -> ARView {
        HardwarePhaseRecorder.during(.presentingCamera) {
            let view = controller.arView
            context.coordinator.attachCoaching(to: view, session: view.session)
            return view
        }
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.setCoachingEnabled(showsCoaching)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Owns the `ARCoachingOverlayView`.
    ///
    /// The coaching overlay is Apple's own onboarding for world tracking and
    /// plane detection; using it rather than a bespoke animation means users get
    /// the guidance they already know from other AR apps, in their own language.
    /// It manages its own presentation, so there is no delegate to implement --
    /// the app only decides whether it may activate.
    @MainActor
    final class Coordinator {
        private weak var overlay: ARCoachingOverlayView?

        func attachCoaching(to view: ARView, session: ARSession) {
            guard overlay == nil else { return }
            let coaching = ARCoachingOverlayView()
            coaching.session = session
            coaching.goal = .verticalPlane
            coaching.activatesAutomatically = true
            coaching.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(coaching)
            NSLayoutConstraint.activate([
                coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                coaching.topAnchor.constraint(equalTo: view.topAnchor),
                coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            overlay = coaching
        }

        func setCoachingEnabled(_ enabled: Bool) {
            guard let overlay else { return }
            overlay.activatesAutomatically = enabled
            if !enabled, overlay.isActive {
                overlay.setActive(false, animated: true)
            }
        }
    }
}

import SwiftUI
import UIKit

/// The application entry point.
///
/// It owns exactly one thing: the composition root. Everything else is created
/// by `AppEnvironment` and injected, so there is a single place to look for what
/// the app depends on.
@main
struct WallFieldApp: App {
    @State private var appEnvironment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
                .tint(Palette.accent)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Camera access may have been changed in Settings while the app
                // was in the background, in either direction.
                appEnvironment.refreshCapabilities()
            }
            if newPhase != .active {
                // Anything holding hardware open is told to stand down. The scan
                // screen owns its own coordinator and handles this too; this is
                // the app-wide backstop that guarantees the idle timer is never
                // left disabled after the app leaves the foreground.
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}

/// Chooses between onboarding and the app proper.
struct RootView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        Group {
            if app.preferences.needsOnboarding {
                OnboardingFlowView()
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.preferences.needsOnboarding)
    }
}

#Preview("First launch") {
    RootView()
        .environment(AppEnvironment.preview())
}

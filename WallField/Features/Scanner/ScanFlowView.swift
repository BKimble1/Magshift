import SwiftUI

/// Hosts a whole scan, from the preparation checklist to review.
///
/// Presented full-screen: a scan needs the whole display, and leaving it is an
/// explicit decision rather than a swipe.
struct ScanFlowView: View {
    /// Called with the saved record, or `nil` if the user left without saving.
    var onFinish: (ScanRecord?) -> Void

    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator: ScanCoordinator?

    var body: some View {
        Group {
            if let coordinator {
                ScanFlowContent(coordinator: coordinator, onFinish: onFinish)
            } else {
                Color(uiColor: .systemBackground)
                    .overlay { ProgressView("Preparing\u{2026}") }
            }
        }
        .onAppear {
            if coordinator == nil {
                coordinator = app.makeScanCoordinator()
            }
        }
        .onDisappear {
            coordinator?.teardown()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                coordinator?.handleBackgrounding()
            }
        }
    }
}

private struct ScanFlowContent: View {
    @Bindable var coordinator: ScanCoordinator
    var onFinish: (ScanRecord?) -> Void

    @Environment(AppEnvironment.self) private var app
    @State private var isPresentingSafety = false
    @State private var isConfirmingReset = false
    @State private var isConfirmingExit = false

    var body: some View {
        ZStack {
            cameraLayer
                .ignoresSafeArea()

            switch coordinator.phase {
            case .preparing:
                PreparationChecklistView(
                    onContinue: { coordinator.beginSession() },
                    onCancel: { onFinish(nil) }
                )
                .background(Color(uiColor: .systemBackground))

            case .mappingWall, .wallLocked, .calibrating:
                SetupOverlay(
                    coordinator: coordinator,
                    onSafety: { isPresentingSafety = true },
                    onExit: { isConfirmingExit = true }
                )

            case .scanning, .paused:
                ScanHUDView(
                    coordinator: coordinator,
                    onSafety: { isPresentingSafety = true },
                    onRequestReset: { isConfirmingReset = true },
                    onExit: { isConfirmingExit = true }
                )

            case .finished:
                ReviewView(coordinator: coordinator, onDone: onFinish)
                    .background(Color(uiColor: .systemBackground))

            case .blocked(let problem):
                ScanBlockedView(
                    problem: problem,
                    onRetry: { coordinator.retryAfterProblem() },
                    onExit: { onFinish(nil) }
                )
                .background(Color(uiColor: .systemBackground))
            }

            if app.runtimeMode.isSimulated {
                VStack {
                    SimulatedDataBanner()
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $isPresentingSafety) { SafetyPageView() }
        .confirmationDialog(
            "Remove every mark from this scan?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Remove all marks", role: .destructive) {
                coordinator.resetMeasurements()
            }
            .accessibilityIdentifier(A11y.scannerConfirmReset)
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("The wall stays locked and the baseline is kept, so you can start the sweep again "
                + "without calibrating.")
        }
        .confirmationDialog(
            "Leave this scan?",
            isPresented: $isConfirmingExit,
            titleVisibility: .visible
        ) {
            Button("Leave without saving", role: .destructive) { onFinish(nil) }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("Nothing measured in this scan has been saved yet.")
        }
        .statusBarHidden(isImmersive)
    }

    private var isImmersive: Bool {
        switch coordinator.phase {
        case .mappingWall, .wallLocked, .calibrating, .scanning, .paused: return true
        case .preparing, .finished, .blocked: return false
        }
    }

    @ViewBuilder
    private var cameraLayer: some View {
        switch coordinator.phase {
        case .preparing, .finished:
            Color.black
        case .mappingWall, .wallLocked, .calibrating, .scanning, .paused, .blocked:
            if let controller = coordinator.arSessionController {
                ARViewContainer(
                    controller: controller,
                    showsCoaching: coordinator.phase == .mappingWall
                )
            } else if let environment = coordinator.simulatedEnvironment {
                SimulatedWallCanvas(
                    environment: environment,
                    clusters: coordinator.clusters,
                    lockedWall: coordinator.lockedWall
                )
            } else {
                Color.black
            }
        }
    }
}

/// Shown when a scan cannot continue.
struct ScanBlockedView: View {
    let problem: ARSessionProblem
    var onRetry: () -> Void
    var onExit: () -> Void

    var body: some View {
        BlockedStateView(
            systemImage: problem.isRecoverable ? "pause.circle" : "exclamationmark.triangle",
            title: problem.headline,
            message: problem.detail,
            primaryTitle: primaryTitle,
            primaryAction: primaryAction,
            secondaryTitle: problem.isRecoverable ? "Leave scan" : nil,
            secondaryAction: problem.isRecoverable ? onExit : nil
        )
    }

    private var primaryTitle: String {
        if problem.isRecoverable { return "Continue" }
        switch problem {
        case .cameraAccessDenied: return "Open Settings"
        default: return "Close"
        }
    }

    private var primaryAction: () -> Void {
        if problem.isRecoverable { return onRetry }
        switch problem {
        case .cameraAccessDenied: return { SystemSettings.open() }
        default: return onExit
        }
    }
}

#Preview {
    ScanFlowView { _ in }
        .environment(AppEnvironment.preview())
}

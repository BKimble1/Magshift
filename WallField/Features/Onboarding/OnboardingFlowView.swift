import SwiftUI

/// First-run flow, and the flow shown again when the safety wording changes.
///
/// # Why it is two screens
///
/// It used to be six: five pages of explanation followed by the acknowledgement.
/// All of that copy still exists and is one tap away from Home -- "How it works"
/// and the safety page render it in full -- but making a first-time user read it
/// before they can reach anything did not make them read it. First run now says
/// what the app does, asks for the one permission it needs, and asks for the one
/// acknowledgement it must have.
///
/// The acknowledgement is unchanged in kind: the last screen is a decision, with
/// an explicit control the user has to operate. Tapping through cannot accept it.
struct OnboardingFlowView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var pageIndex = 0
    @State private var hasAcknowledged = false
    @State private var cameraAuthorization = DeviceCapabilities.readCameraAuthorization()
    @State private var isRequestingCamera = false
    @State private var isPresentingSafety = false

    private var isOnAcknowledgement: Bool { pageIndex >= 1 }

    var body: some View {
        VStack(spacing: 0) {
            if app.runtimeMode.isSimulated {
                SimulatedDataBanner()
            }
            if app.preferences.isReacknowledging, !isOnAcknowledgement {
                revisedNotice
            }

            TabView(selection: $pageIndex) {
                introPage
                    .tag(0)
                acknowledgementPage
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
                .padding(Theme.Spacing.medium)
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $isPresentingSafety) {
            SafetyPageView()
        }
    }

    private var revisedNotice: some View {
        Text("The safety information has been updated. Please read it again.")
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.top, Theme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Page one

    private var introPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 44))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)

                Text("What \(Branding.productName) does")
                    .font(Theme.Typography.screenTitle)
                    .fixedSize(horizontal: false, vertical: true)

                Text(SafetyCopy.inShort)
                    .font(Theme.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)

                Card(title: "What it cannot do", systemImage: "eye.slash") {
                    BulletList(items: SafetyCopy.firstRunLimits)
                }

                Button("Read the full safety and limitations") {
                    isPresentingSafety = true
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.extraLarge)
        }
    }

    // MARK: - Page two

    private var acknowledgementPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 44))
                        .foregroundStyle(Palette.caution)
                        .accessibilityHidden(true)
                    Text("Before you start")
                        .font(Theme.Typography.screenTitle)
                }

                Text(SafetyCopy.canonicalStatement)
                    .font(Theme.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)

                // Simulated data never opens the camera, and asking for access
                // there would put a system alert in front of the UI tests.
                if !app.runtimeMode.isSimulated {
                    cameraAccessCard
                }

                Card(title: SafetyCopy.beforeYouDrillTitle, systemImage: "exclamationmark.triangle") {
                    BulletList(items: SafetyCopy.beforeYouDrillPoints)
                }

                Toggle(isOn: $hasAcknowledged) {
                    Text(SafetyCopy.acknowledgementStatement)
                        .font(Theme.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier(A11y.onboardingAcknowledgeToggle)

                Text(SafetyCopy.neverDoThis)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.extraLarge)
        }
    }

    private var cameraAccessCard: some View {
        Card(title: "Camera access", systemImage: "camera") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text(SafetyCopy.whyCameraAccess)
                    .font(Theme.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)

                switch cameraAuthorization {
                case .authorized:
                    Label("Camera access allowed", systemImage: "checkmark.circle.fill")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Palette.accent)
                case .notDetermined:
                    Button("Allow camera access") {
                        requestCameraAccess()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isRequestingCamera)
                    .accessibilityIdentifier(A11y.onboardingAllowCamera)
                case .denied:
                    Text("Camera access is off, so scanning is not possible. Sensor diagnostics "
                        + "still work, and you can turn the camera on later in Settings.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") { SystemSettings.open() }
                        .buttonStyle(SecondaryButtonStyle())
                case .restricted:
                    Text("Camera access is restricted on this device, so scanning is not possible. "
                        + "Sensor diagnostics still work.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if isOnAcknowledgement {
            Button("I understand \u{2014} continue") {
                app.preferences.recordSafetyAcknowledgement()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!hasAcknowledged)
            .accessibilityIdentifier(A11y.onboardingAcceptButton)
            .accessibilityHint(hasAcknowledged
                ? "Saves your acknowledgement and opens the app."
                : "Turn on the acknowledgement above to continue.")
        } else {
            Button("Continue") {
                withAnimation { pageIndex += 1 }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier(A11y.onboardingContinue)
        }
    }

    @MainActor
    private func requestCameraAccess() {
        guard !isRequestingCamera else { return }
        isRequestingCamera = true
        Task {
            cameraAuthorization = await DeviceCapabilities.requestCameraAccess()
            // Everything downstream reads the environment's copy, which was taken
            // at launch and is now out of date.
            app.refreshCapabilities()
            isRequestingCamera = false
        }
    }
}

#Preview {
    OnboardingFlowView()
        .environment(AppEnvironment.preview())
}

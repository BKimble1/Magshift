import SwiftUI

/// Settings, safety, sensor sensitivity and developer tools.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var isConfirmingDeleteAll = false
    @State private var didRequestRestart = false

    var body: some View {
        @Bindable var preferences = app.preferences
        List {
            if let failure = app.storageFailure {
                Section {
                    Label(failure, systemImage: "externaldrive.badge.exclamationmark")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Palette.caution)
                }
            }

            Section {
                NavigationLink {
                    SafetyPageView(isEmbedded: true)
                } label: {
                    Label("Safety & limitations", systemImage: "exclamationmark.triangle")
                }
                .accessibilityIdentifier(A11y.settingsSafety)

                NavigationLink {
                    HowItWorksView()
                } label: {
                    Label("How it works", systemImage: "book")
                }
            } footer: {
                Text(SafetyCopy.compactStatement)
            }

            Section {
                Picker("Sensitivity", selection: $preferences.sensitivity) {
                    ForEach(SensitivityPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(A11y.settingsSensitivity)

                Text(preferences.sensitivity.explanation)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                thresholdSummary
            } header: {
                Text("Detection")
            } footer: {
                Text("Sensitivity changes the statistical thresholds only. No setting makes "
                    + "\(Branding.productName) able to identify what caused a reading.")
            }

            Section("Feedback") {
                Toggle("Haptics", isOn: $preferences.hapticsEnabled)
                    .onChange(of: preferences.hapticsEnabled) { _, _ in app.applyFeedbackPreferences() }
                Toggle("Sound", isOn: $preferences.soundEnabled)
                    .onChange(of: preferences.soundEnabled) { _, _ in app.applyFeedbackPreferences() }
                Toggle("Show the wall overlay", isOn: $preferences.wallOverlayVisible)
            }

            Section {
                capabilityRow("ARKit world tracking", app.capabilities.supportsWorldTracking)
                capabilityRow("Vertical plane detection", app.capabilities.supportsVerticalPlaneDetection)
                capabilityRow("Scene depth (LiDAR)", app.capabilities.supportsSceneDepth)
                capabilityRow("Camera access", app.capabilities.cameraAuthorization.isUsable)
                if app.capabilities.cameraAuthorization == .denied {
                    Button("Open Settings") { SystemSettings.open() }
                }
            } header: {
                Text("This device")
            } footer: {
                Text("Scene depth is not required. \(Branding.productName) works the same on iPhones "
                    + "without LiDAR, and does not use depth data.")
            }

            Section {
                LabeledContent("App version", value: Branding.versionDisplayString)
                LabeledContent("Algorithm version", value: AlgorithmVersion.current)
                LabeledContent("Data format", value: "version \(ScanRecord.currentSchemaVersion)")
                LabeledContent("Organisation", value: Branding.organizationName)
                if let acknowledgedAt = preferences.acknowledgedAt {
                    LabeledContent(
                        "Safety acknowledged",
                        value: Format.scanDate.string(from: acknowledgedAt)
                    )
                }
            } header: {
                Text("About")
            } footer: {
                Text("Everything \(Branding.productName) records stays on this iPhone. There is no "
                    + "account, no analytics, no advertising and no network connection. Scans leave the "
                    + "device only when you export and share them yourself.")
            }

            Section {
                Button("Delete all saved scans", role: .destructive) {
                    isConfirmingDeleteAll = true
                }
            } footer: {
                Text("Removes every scan stored on this iPhone. This cannot be undone.")
            }

            if RuntimeMode.developerToolsAvailable {
                developerSection
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete every saved scan?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                Task { await app.library.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var thresholdSummary: some View {
        let config = app.preferences.detectorConfiguration
        return VStack(alignment: .leading, spacing: 2) {
            Text("A reading must exceed both "
                + "\(Format.decimal(config.enterZScore, decimals: 1)) sigma and "
                + "\(Format.microtesla(config.absoluteFloorMicrotesla)), in at least "
                + "\(config.persistenceRequired) of \(config.persistenceWindow) samples.")
            if AlgorithmVersion.isProvisional {
                Text("These values are provisional until validated against known ground truth.")
                    .foregroundStyle(Palette.caution)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func capabilityRow(_ title: String, _ available: Bool) -> some View {
        LabeledContent(title) {
            // Availability is shown with a symbol and a word, never colour alone.
            Label(
                available ? "Available" : "Not available",
                systemImage: available ? "checkmark.circle" : "xmark.circle"
            )
            .font(.caption)
            .foregroundStyle(available ? Color.secondary : Palette.caution)
        }
    }

    @ViewBuilder
    private var developerSection: some View {
        Section {
            Toggle("Use simulated data", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: RuntimeMode.developerPreferenceKey) },
                set: {
                    UserDefaults.standard.set($0, forKey: RuntimeMode.developerPreferenceKey)
                    didRequestRestart = true
                }
            ))
            .accessibilityIdentifier(A11y.settingsSimulatedData)

            if didRequestRestart {
                Text("Quit and reopen \(Branding.productName) for this to take effect. The data source "
                    + "is fixed for the lifetime of the process so no screen can be half-simulated.")
                    .font(.caption)
                    .foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Current mode", value: app.runtimeMode.rawValue)
        } header: {
            Text("Developer")
        } footer: {
            Text("Debug builds only. Simulated data is compiled out of Release builds entirely, so it "
                + "cannot reach the App Store.")
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(AppEnvironment.preview())
}

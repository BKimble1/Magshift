import SwiftUI

/// The live scan interface.
///
/// Everything on it is throttled to `Theme.readoutUpdatesPerSecond`, sits on a
/// material so it stays legible over any camera image, and keeps every control
/// at or above `Theme.minimumTouchTarget`.
struct ScanHUDView: View {
    @Bindable var coordinator: ScanCoordinator
    var onSafety: () -> Void
    var onRequestReset: () -> Void
    var onExit: () -> Void

    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingLegend = true

    private var isPaused: Bool { coordinator.phase == .paused }

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            topBar
            HStack(alignment: .top) {
                Spacer(minLength: 0)
                if isShowingLegend {
                    HeatMapLegend()
                        .frame(maxWidth: 190)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            Spacer(minLength: 0)
            Crosshair(isActive: coordinator.currentHit != nil && !isPaused)
            Spacer(minLength: 0)
            if let obstruction = coordinator.obstruction {
                obstructionBanner(obstruction)
            }
            readoutPanel
            controlBar
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.medium)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isShowingLegend)
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button(action: onExit) {
                Image(systemName: "xmark")
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Leave scan")

            VStack(alignment: .leading, spacing: 1) {
                Text(coordinator.readout.detectorState.displayName)
                    .font(.caption.weight(.semibold))
                Text("\(Format.duration(coordinator.elapsed)) \u{00B7} pass \(coordinator.passIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .background(Theme.hudMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(A11y.scannerStatus)

            Text("\(coordinator.clusters.count)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.tight)
                .background(Theme.hudMaterial, in: Capsule())
                .accessibilityIdentifier(A11y.scannerClusterCount)
                .accessibilityLabel("\(coordinator.clusters.count) magnetic anomalies mapped")

            Spacer(minLength: 0)

            optionsMenu

            Button(action: onSafety) {
                Image(systemName: "exclamationmark.triangle")
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Safety and limitations")
            .accessibilityIdentifier(A11y.scannerSafety)
        }
        .padding(.top, Theme.Spacing.small)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Wall overlay", isOn: Binding(
                get: { coordinator.isWallOverlayVisible },
                set: { coordinator.isWallOverlayVisible = $0 }
            ))
            .accessibilityIdentifier(A11y.scannerOverlayToggle)

            Toggle("Legend", isOn: $isShowingLegend)

            Toggle("Haptics", isOn: Binding(
                get: { app.preferences.hapticsEnabled },
                set: {
                    app.preferences.hapticsEnabled = $0
                    app.applyFeedbackPreferences()
                }
            ))

            Toggle("Sound", isOn: Binding(
                get: { app.preferences.soundEnabled },
                set: {
                    app.preferences.soundEnabled = $0
                    app.applyFeedbackPreferences()
                }
            ))
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: Theme.minimumTouchTarget, minHeight: Theme.minimumTouchTarget)
                .background(Theme.hudMaterial, in: RoundedRectangle(
                    cornerRadius: Theme.Radius.medium, style: .continuous
                ))
        }
        .accessibilityLabel("Scan options")
    }

    // MARK: - Readouts

    private func obstructionBanner(_ reason: QualityReason) -> some View {
        Label(reason.guidance, systemImage: "exclamationmark.circle")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Palette.caution.opacity(0.9))
            )
            .foregroundStyle(Color.black)
            .accessibilityLabel(reason.explanation)
    }

    private var readoutPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Format.microtesla(coordinator.readout.magnitude))
                        .font(Theme.Typography.readout)
                    Text("field strength")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Spacing.medium)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.signedMicrotesla(coordinator.readout.delta))
                        .font(Theme.Typography.readout)
                    Text("from baseline")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Field \(Format.microtesla(coordinator.readout.magnitude)). "
                    + "Change from baseline \(Format.signedMicrotesla(coordinator.readout.delta))."
            )

            StrengthMeter(
                level: coordinator.readout.meterLevel(configuration: coordinator.configuration),
                thresholdFraction: coordinator.readout.thresholdFraction,
                band: coordinator.readout.band
            )

            HStack(spacing: Theme.Spacing.medium) {
                miniStat("z", Format.decimal(coordinator.readout.robustZScore, decimals: 1))
                miniStat("rate", Format.hertz(coordinator.readout.timing.measuredRate))
                miniStat("accuracy", coordinator.readout.accuracy.displayName)
                if let distance = coordinator.readout.wallDistance {
                    miniStat("distance", Format.distance(distance))
                }
            }

            Text(SafetyCopy.compactStatement)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.hudMaterial)
        )
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            if isPaused {
                Button {
                    coordinator.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(HUDButtonStyle(isProminent: true))
                .accessibilityIdentifier(A11y.scannerResume)
            } else {
                Button {
                    coordinator.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(HUDButtonStyle())
                .accessibilityIdentifier(A11y.scannerPause)
            }

            Button {
                coordinator.beginNewPass()
            } label: {
                Label("New pass", systemImage: "arrow.trianglehead.2.clockwise")
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityIdentifier(A11y.scannerNewPass)
            .accessibilityHint("Marks the start of another pass. Readings measured again in the same "
                + "place become repeated.")

            Button {
                coordinator.undoLastCluster()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(HUDButtonStyle())
            .disabled(coordinator.clusters.isEmpty)
            .accessibilityLabel("Undo last mark")
            .accessibilityIdentifier(A11y.scannerUndo)

            Button(action: onRequestReset) {
                Image(systemName: "trash")
            }
            .buttonStyle(HUDButtonStyle())
            .disabled(coordinator.clusters.isEmpty)
            .accessibilityLabel("Remove all marks")
            .accessibilityIdentifier(A11y.scannerReset)

            Button {
                coordinator.finish()
            } label: {
                Text("Finish")
            }
            .buttonStyle(HUDButtonStyle(isProminent: true))
            .accessibilityIdentifier(A11y.scannerFinish)
        }
    }
}

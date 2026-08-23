import SwiftUI

/// Controls shown over the camera while the user maps a wall, locks it and
/// calibrates.
struct SetupOverlay: View {
    @Bindable var coordinator: ScanCoordinator
    var onSafety: () -> Void
    var onExit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            Crosshair(isActive: coordinator.targetedWallID != nil)
            Spacer(minLength: 0)
            instructionPanel
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.medium)
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button {
                onExit()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Leave scan")

            statusPill

            Spacer(minLength: 0)

            Button(action: onSafety) {
                Image(systemName: "exclamationmark.triangle")
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Safety and limitations")
            .accessibilityIdentifier(A11y.scannerSafety)
        }
        .padding(.top, Theme.Spacing.small)
    }

    private var statusPill: some View {
        Text(coordinator.trackingQuality.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .background(Theme.hudMaterial, in: Capsule())
            .accessibilityIdentifier(A11y.scannerStatus)
    }

    // MARK: - Bottom

    @ViewBuilder
    private var instructionPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            switch coordinator.phase {
            case .mappingWall:
                mappingContent
            case .wallLocked:
                lockedContent
            case .calibrating:
                calibratingContent
            default:
                EmptyView()
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.hudMaterial)
        )
    }

    private var mappingContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Map the wall")
                .font(Theme.Typography.cardTitle)
            Text(mappingInstruction)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let instruction = coordinator.trackingQuality.recoveryInstruction {
                Label(instruction, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Palette.caution)
            }

            Button("Lock this wall") {
                coordinator.lockTargetedWall()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(coordinator.targetedWallID == nil)
            .accessibilityIdentifier(A11y.scannerLockWall)
            .accessibilityHint(coordinator.targetedWallID == nil
                ? "Aim the crosshair at a wall the app has mapped."
                : "Locks the wall under the crosshair for this scan.")
        }
    }

    private var mappingInstruction: String {
        let count = coordinator.candidateWalls.count
        if count == 0 {
            return "Point the camera at a wall and move the phone slowly so it can be mapped. "
                + "Mapped walls are shaded blue."
        }
        if coordinator.targetedWallID == nil {
            return "\(count) wall\(count == 1 ? "" : "s") mapped. Put the crosshair on the one you want "
                + "to scan."
        }
        return "Ready. Locking keeps every reading on this one surface for the whole scan."
    }

    private var lockedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(coordinator.calibration == nil ? "Calibrate the field" : "Ready to scan")
                .font(Theme.Typography.cardTitle)

            if let rejection = coordinator.calibrationRejection {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rejection.headline)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.caution)
                    Text(rejection.recovery)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let calibration = coordinator.calibration {
                Text("Baseline \(Format.microtesla(calibration.baselineMagnitude)), "
                    + "noise \(Format.microtesla(calibration.sigma, decimals: 2)). "
                    + "Move slowly and keep the crosshair on the wall.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Hold the phone still against the wall for a few seconds so the quiet field here "
                    + "can be measured.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Spacing.small) {
                Button(coordinator.calibration == nil ? "Calibrate" : "Recalibrate") {
                    coordinator.startCalibration()
                }
                .buttonStyle(coordinator.calibration == nil
                    ? AnyButtonStyleBox(PrimaryButtonStyle())
                    : AnyButtonStyleBox(SecondaryButtonStyle()))
                .accessibilityIdentifier(A11y.scannerCalibrate)

                if coordinator.calibration != nil {
                    Button("Start scan") {
                        coordinator.startScanning()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier(A11y.scannerStart)
                }
            }

            Button("Choose a different wall") {
                coordinator.unlockWall()
            }
            .font(.caption)
            .padding(.top, Theme.Spacing.hairline)
        }
    }

    private var calibratingContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Hold the phone still")
                .font(Theme.Typography.cardTitle)
            Text("Measuring the quiet field and how much it naturally wobbles. Keep the phone against "
                + "the wall in the orientation you will scan with.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ProgressView(value: coordinator.calibrationProgress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Calibration progress")
                .accessibilityValue("\(Int(coordinator.calibrationProgress * 100)) percent")

            Button("Cancel") {
                coordinator.cancelCalibration()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// Type-erasing wrapper so a view can pick between two button styles at runtime.
///
/// SwiftUI's `ButtonStyle` is not existential-friendly, and the alternative --
/// duplicating the whole button for each branch -- duplicates its accessibility
/// configuration too, which is exactly the kind of duplication that drifts.
struct AnyButtonStyleBox: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}

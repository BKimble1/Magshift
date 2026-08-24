import Charts
import SwiftUI

/// Sensor diagnostics and validation lab.
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: DiagnosticsModel?
    @State private var exporter = ExportController()

    var body: some View {
        Group {
            if let model {
                content(model: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Sensor diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil {
                model = DiagnosticsModel(
                    fieldService: app.makeFieldService(),
                    spatialProvider: app.capabilities.supportsWorldTracking
                        ? app.makeSpatialProvider()
                        : nil,
                    capabilities: app.capabilities,
                    configuration: app.preferences.detectorConfiguration,
                    isSimulated: app.runtimeMode.isSimulated
                )
            }
            model?.start()
        }
        .onDisappear { model?.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Stopping on the way out is not enough: without the restart the
            // screen stays dead after the app returns, with no live readings and
            // no way to record, until the user navigates away and back.
            // `start()` is a no-op while already streaming.
            if phase == .active {
                model?.start()
            } else {
                model?.stop()
            }
        }
        .sheet(isPresented: Binding(
            get: { exporter.isPresentingShareSheet },
            set: { exporter.isPresentingShareSheet = $0 }
        )) {
            ShareSheet(urls: exporter.urls) { exporter.cleanUp() }
        }
    }

    private func content(model: DiagnosticsModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if model.isSimulated { SimulatedDataBanner() }

                purposeCard

                if model.availability.isUnavailable {
                    Card(title: "No magnetic data", systemImage: "sensor.tag.radiowaves.forward.fill") {
                        Text(model.availability.failureDescription
                            ?? "This device does not report magnetic-field data.")
                            .font(Theme.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    liveCard(model: model)
                    chartCard(model: model)
                    detectorCard(model: model)
                    calibrationCard(model: model)
                    arCard(model: model)
                    recordingCard(model: model)
                }
            }
            .padding(Theme.Spacing.medium)
        }
    }

    private var purposeCard: some View {
        Card(title: "What this is for", systemImage: "flask") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("""
                    This screen records exactly what the sensor reports, so readings can be compared \
                    against known ground truth on a real wall. It is the evidence behind any claim \
                    \(Branding.productName) makes.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SafetyCopy.neverDoThis)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.Typography.body)
        }
    }

    private func liveCard(model: DiagnosticsModel) -> some View {
        Card(title: "Live field", systemImage: "waveform") {
            VStack(spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(label: "X", value: Format.microtesla(model.latest?.x ?? 0, decimals: 2))
                    StatTile(label: "Y", value: Format.microtesla(model.latest?.y ?? 0, decimals: 2))
                    StatTile(label: "Z", value: Format.microtesla(model.latest?.z ?? 0, decimals: 2))
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Magnitude",
                        value: Format.microtesla(model.latest?.magnitude ?? 0, decimals: 2)
                    )
                    StatTile(
                        label: "Accuracy",
                        value: model.latest?.accuracy.displayName ?? "\u{2014}",
                        caption: model.latest?.accuracy.recoveryInstruction
                    )
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Measured rate",
                        value: Format.hertz(model.timing.measuredRate),
                        caption: "Requested \(Format.hertz(model.requestedSampleRate))"
                    )
                    StatTile(
                        label: "Worst gap",
                        value: Format.milliseconds(model.timing.maximumGap),
                        caption: model.timing.isHealthy ? "Timing healthy" : "Timing unhealthy"
                    )
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Source",
                        value: model.latest?.source.displayName ?? "\u{2014}",
                        caption: (model.latest?.source.isAcceptableForDetection ?? true)
                            ? nil
                            : "Cannot anchor markers"
                    )
                    StatTile(
                        label: "Clock offset",
                        value: model.coreMotionClockOffset.map {
                            Format.milliseconds($0)
                        } ?? "measuring\u{2026}",
                        caption: "systemUptime \u{2212} Core Motion"
                    )
                }
            }
        }
    }

    private func chartCard(model: DiagnosticsModel) -> some View {
        Card(title: "Field magnitude", systemImage: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Chart {
                    ForEach(model.chartPoints) { point in
                        LineMark(
                            x: .value("Time", point.elapsed),
                            y: .value("Magnitude", point.magnitude)
                        )
                        .foregroundStyle(Palette.accent)
                    }
                    if model.calibration != nil {
                        ForEach(model.chartPoints) { point in
                            LineMark(
                                x: .value("Time", point.elapsed),
                                y: .value("Baseline", point.baseline),
                                series: .value("Series", "baseline")
                            )
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(dash: [4, 3]))
                        }
                    }
                }
                .chartYAxisLabel(Format.microteslaSymbol)
                .chartXAxisLabel("seconds")
                .frame(height: 180)
                .accessibilityLabel("Field magnitude over the last twelve seconds")
                .accessibilityValue(Format.microtesla(model.latest?.magnitude ?? 0))

                Text("Last 12 seconds, redrawn at 5 Hz.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detectorCard(model: DiagnosticsModel) -> some View {
        Card(title: "Detector", systemImage: "function") {
            VStack(spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(label: "State", value: model.latest?.detectorState.displayName ?? "\u{2014}")
                    StatTile(
                        label: "Persistence",
                        value: "\(model.latest?.persistence ?? 0)"
                            + "/\(app.preferences.detectorConfiguration.persistenceWindow)"
                    )
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Baseline",
                        value: Format.microtesla(model.latest?.baseline ?? 0, decimals: 3)
                    )
                    StatTile(
                        label: "Delta",
                        value: Format.signedMicrotesla(model.latest?.delta ?? 0, decimals: 3)
                    )
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Robust z",
                        value: Format.decimal(model.latest?.robustZScore ?? 0, decimals: 2),
                        caption: "Enter at "
                            + Format.decimal(app.preferences.detectorConfiguration.enterZScore, decimals: 1)
                    )
                    StatTile(
                        label: "Sigma",
                        value: Format.microtesla(model.latest?.sigma ?? 0, decimals: 4)
                    )
                }
                if AlgorithmVersion.isProvisional {
                    Text("Thresholds in this build are provisional and unvalidated against physical "
                        + "ground truth.")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func calibrationCard(model: DiagnosticsModel) -> some View {
        Card(title: "Baseline calibration", systemImage: "scope") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if model.isCalibrating {
                    ProgressView(value: model.calibrationProgress)
                    Text("Hold the phone still.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelCalibration() }
                        .buttonStyle(SecondaryButtonStyle())
                } else if let calibration = model.calibration {
                    HStack(spacing: Theme.Spacing.medium) {
                        StatTile(
                            label: "Baseline",
                            value: Format.microtesla(calibration.baselineMagnitude, decimals: 3)
                        )
                        StatTile(
                            label: "MAD",
                            value: Format.microtesla(calibration.medianAbsoluteDeviation, decimals: 4),
                            caption: "raw \(Format.microtesla(calibration.rawMedianAbsoluteDeviation, decimals: 4))"
                        )
                    }
                    HStack(spacing: Theme.Spacing.medium) {
                        StatTile(
                            label: "Sigma",
                            value: Format.microtesla(calibration.sigma, decimals: 4),
                            caption: calibration.sigmaWasFloored ? "At the noise floor" : "1.4826 x MAD"
                        )
                        StatTile(label: "Samples", value: "\(calibration.sampleCount)")
                    }
                    Button("Recalibrate") { model.startCalibration() }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    if let rejection = model.calibrationRejection {
                        Text(rejection.headline)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.caution)
                        Text(rejection.recovery)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Calibrate") { model.startCalibration() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func arCard(model: DiagnosticsModel) -> some View {
        if app.capabilities.supportsWorldTracking {
            Card(title: "AR tracking", systemImage: "arkit") {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Toggle("Run an AR session", isOn: Binding(
                        get: { model.isARActive },
                        set: { model.setARActive($0) }
                    ))
                    if model.isARActive {
                        HStack(spacing: Theme.Spacing.medium) {
                            StatTile(
                                label: "Tracking",
                                value: model.trackingQuality?.displayName ?? "\u{2014}"
                            )
                            StatTile(
                                label: "Raycast distance",
                                value: model.raycastDistance.map(Format.distance) ?? "\u{2014}",
                                caption: model.isWallLocked ? nil : "Lock a wall to measure"
                            )
                        }
                        // The preview is not decoration: the raycast is taken from
                        // the centre of this view, so the distance readout is only
                        // meaningful while it is on screen and laid out.
                        if let controller = model.arSessionController {
                            ZStack {
                                ARViewContainer(controller: controller, showsCoaching: false)
                                Crosshair(isActive: model.raycastDistance != nil)
                            }
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(
                                cornerRadius: Theme.Radius.small, style: .continuous
                            ))
                            .accessibilityLabel("Camera preview used to measure raycast distance")
                        }
                        if !model.isWallLocked {
                            Button("Lock the wall in view") { model.lockTargetedWall() }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(model.targetedWallID == nil)
                        }
                        Text("Distance is measured from the centre of the preview above to the "
                            + "locked wall.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func recordingCard(model: DiagnosticsModel) -> some View {
        @Bindable var model = model
        return Card(title: "Record a run", systemImage: "record.circle") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                TextField("Run label, e.g. \"control region, case off\"", text: $model.runLabel)
                    .textFieldStyle(.roundedBorder)
                TextField("Notes", text: $model.runNotes, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)

                if model.isRecording {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                        Text("\(model.recordedCount) samples")
                            .font(Theme.Typography.readoutSmall)
                    }
                    Button("Stop recording") {
                        model.finishRecording()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier(A11y.diagnosticsStop)
                } else {
                    Button("Start recording") {
                        model.startRecording()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.isStreaming)
                    .accessibilityIdentifier(A11y.diagnosticsStart)
                }

                if model.didHitRecordingLimit {
                    Text("Recording stopped at the "
                        + "\(DiagnosticsModel.maximumRecordedSamples)-sample limit.")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                }

                if let run = model.completedRun {
                    Divider()
                    Text("\(run.label): \(run.samples.count) samples over "
                        + "\(Format.duration(run.duration))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await exporter.prepareDiagnostics(run: run) }
                    } label: {
                        if exporter.isPreparing {
                            ProgressView()
                        } else {
                            Label("Export CSV and JSON", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(exporter.isPreparing || run.samples.isEmpty)
                    .accessibilityIdentifier(A11y.diagnosticsExport)
                }

                if let error = exporter.error {
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

}

#Preview {
    NavigationStack { DiagnosticsView() }
        .environment(AppEnvironment.preview())
}

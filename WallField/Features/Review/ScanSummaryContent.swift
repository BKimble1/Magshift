import SwiftUI

/// The read-only body of a scan result.
///
/// Shared by the review screen (before saving) and by saved-scan detail, so the
/// numbers and the safety wording a user sees at the end of a scan are exactly
/// what they see when they open it again a month later.
struct ScanSummaryContent: View {
    let record: ScanRecord
    var onOpenSafety: () -> Void

    @State private var selectedCluster: AnomalyCluster?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if record.isSimulated {
                SimulatedDataBanner()
            }

            headline

            WallMapView(
                bounds: record.summaryBounds,
                clusters: record.clusters,
                crosshair: nil,
                onSelect: { selectedCluster = $0 }
            )
            .frame(height: 280)
            .accessibilityHint(record.clusters.isEmpty ? "" : "Tap a mark for its numbers.")

            HeatMapLegend()

            countsCard
            calibrationCard
            qualityCard

            if !record.notes.isEmpty {
                Card(title: "Notes", systemImage: "note.text") {
                    Text(record.notes)
                        .font(Theme.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !record.validationTags.isEmpty {
                Card(title: "Validation tags", systemImage: "tag") {
                    Text(record.validationTags.joined(separator: ", "))
                        .font(Theme.Typography.body)
                }
            }

            provenanceCard

            SafetyStatementCard()
            SafetyReminderBar(text: "Read the full safety and limitations page.", action: onOpenSafety)
        }
        .sheet(item: $selectedCluster) { cluster in
            ClusterDetailSheet(cluster: cluster, configuration: record.detectorConfiguration)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headline: some View {
        if record.hasNoAnomalies {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                NoAnomalyStatement()
            }
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Palette.caution.opacity(0.12))
            )
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("\(record.clusterCount) magnetic "
                    + "\(record.clusterCount == 1 ? "anomaly" : "anomalies") mapped")
                    .font(Theme.Typography.sectionTitle)
                    .accessibilityIdentifier(A11y.reviewClusterCount)
                Text("\(record.repeatedClusterCount) repeated on a later pass, "
                    + "\(record.unconfirmedClusterCount) unconfirmed.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var countsCard: some View {
        Card(title: "This scan", systemImage: "square.grid.2x2") {
            VStack(spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(label: "Recorded", value: Format.scanDate.string(from: record.createdAt))
                    StatTile(label: "Duration", value: Format.duration(record.duration))
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(label: "Passes", value: "\(record.quality.passCount)")
                    StatTile(label: "Accepted readings", value: "\(record.measurements.count)")
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(label: "Repeated", value: "\(record.repeatedClusterCount)",
                             caption: SafetyCopy.repeatedExplanation)
                    StatTile(label: "Unconfirmed", value: "\(record.unconfirmedClusterCount)",
                             caption: SafetyCopy.unconfirmedExplanation)
                }
            }
        }
    }

    private var calibrationCard: some View {
        Card(title: "Baseline and noise", systemImage: "chart.bar") {
            VStack(spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Baseline",
                        value: Format.microtesla(record.calibration.baselineMagnitude, decimals: 2),
                        caption: "Median quiet field"
                    )
                    StatTile(
                        label: "Noise (sigma)",
                        value: Format.microtesla(record.calibration.sigma, decimals: 3),
                        caption: record.calibration.sigmaWasFloored
                            ? "Raised to the noise floor"
                            : "1.4826 x MAD"
                    )
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Threshold",
                        value: "\(Format.decimal(record.detectorConfiguration.enterZScore, decimals: 1))"
                            + " sigma / \(Format.microtesla(record.detectorConfiguration.absoluteFloorMicrotesla))",
                        caption: "Both had to be exceeded"
                    )
                    StatTile(
                        label: "Sensitivity",
                        value: record.sensitivity.displayName
                    )
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Calibration samples",
                        value: "\(record.calibration.sampleCount)",
                        caption: Format.duration(record.calibration.duration)
                    )
                    StatTile(
                        label: "Sensor accuracy",
                        value: record.calibration.worstAccuracy.displayName,
                        caption: "Worst during calibration"
                    )
                }
            }
        }
    }

    private var qualityCard: some View {
        Card(title: "Scan quality", systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Sample rate",
                        value: Format.hertz(record.quality.measuredSampleRate),
                        caption: "Measured, not requested"
                    )
                    StatTile(
                        label: "Tracking normal",
                        value: "\(Int((record.quality.trackingNormalFraction * 100).rounded()))%"
                    )
                }
                HStack(spacing: Theme.Spacing.medium) {
                    StatTile(
                        label: "Sync error",
                        value: Format.milliseconds(record.quality.meanTimingError),
                        caption: "Worst \(Format.milliseconds(record.quality.worstTimingError))"
                    )
                    StatTile(
                        label: "Scan speed",
                        value: String(format: "%.2f m/s", record.quality.meanCameraSpeed)
                    )
                }
                if !record.quality.rankedRejections.isEmpty {
                    Divider()
                    Text("Readings that were not placed")
                        .font(.caption.weight(.semibold))
                    ForEach(record.quality.rankedRejections.prefix(4)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                            Text("\(entry.count)x")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                            Text(entry.reason.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var provenanceCard: some View {
        Card(title: "How this was produced", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                labelled("App", record.appVersion)
                labelled("Algorithm", record.algorithmVersion)
                labelled("Device", record.device.model)
                labelled("System", record.device.systemVersion)
                labelled("Data format", "version \(record.schemaVersion)")
                if AlgorithmVersion.isProvisional {
                    Text("The detection thresholds in this build are provisional and have not yet been "
                        + "measured against known ground truth.")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Spacing.tight)
                }
            }
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.small)
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The numbers behind one mark.
struct ClusterDetailSheet: View {
    let cluster: AnomalyCluster
    let configuration: DetectorConfiguration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: cluster.strengthBand.symbolName)
                            .foregroundStyle(Palette.color(forBand: cluster.strengthBand))
                        Text(SafetyCopy.anomalyLabel)
                            .font(Theme.Typography.sectionTitle)
                    }
                    Text("\(cluster.strengthBand.displayName) \u{00B7} \(cluster.confidence.displayName)")
                        .font(Theme.Typography.body)
                        .foregroundStyle(.secondary)

                    Card(title: "Measurement", systemImage: "ruler") {
                        VStack(spacing: Theme.Spacing.small) {
                            HStack(spacing: Theme.Spacing.medium) {
                                StatTile(label: "Peak change",
                                         value: Format.signedMicrotesla(cluster.peakDelta, decimals: 2))
                                StatTile(label: "Peak z-score",
                                         value: Format.decimal(cluster.peakZScore, decimals: 2),
                                         caption: "Threshold "
                                            + Format.decimal(configuration.enterZScore, decimals: 1))
                            }
                            HStack(spacing: Theme.Spacing.medium) {
                                StatTile(label: "Samples", value: "\(cluster.sampleCount)")
                                StatTile(label: "Passes", value: "\(cluster.passCount)")
                            }
                            HStack(spacing: Theme.Spacing.medium) {
                                StatTile(label: "Position on wall",
                                         value: String(format: "x %.2f m, y %.2f m",
                                                       cluster.wallPoint.x, cluster.wallPoint.y))
                                StatTile(label: "Direction",
                                         value: cluster.polarity.displayName)
                            }
                            HStack(spacing: Theme.Spacing.medium) {
                                StatTile(label: "Spatial quality",
                                         value: cluster.bestRaycastQuality.displayName)
                                StatTile(label: "Worst sync error",
                                         value: Format.milliseconds(cluster.worstTimingError))
                            }
                        }
                    }

                    Card(title: "What this does not tell you", systemImage: "exclamationmark.triangle") {
                        Text(SafetyCopy.confidenceMeaning)
                            .font(Theme.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Spacing.medium)
            }
            .navigationTitle("Mark details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

import SwiftUI

/// The app's front door.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var isPresentingScan = false
    @State private var isPresentingSafety = false
    @State private var path = NavigationPath()

    private var capabilityBlock: CapabilityBlock? {
        CapabilityBlock.evaluate(app.capabilities, runtimeMode: app.runtimeMode)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: Theme.Spacing.medium) {
                    header
                    if let interruptedPhase = app.interruptedPhase {
                        interruptedCard(interruptedPhase)
                    }
                    if let capabilityBlock {
                        capabilityCard(capabilityBlock)
                    } else {
                        newScanButton
                    }
                    SafetyReminderBar { isPresentingSafety = true }
                    recentScansSection
                    toolsSection
                    footer
                }
                .padding(Theme.Spacing.medium)
            }
            .navigationTitle(Branding.productName)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if app.runtimeMode.isSimulated {
                    SimulatedDataBanner()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier(A11y.homeSettings)
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .history: HistoryListView()
                case .diagnostics: DiagnosticsView()
                case .settings: SettingsView()
                case .howItWorks: HowItWorksView()
                case .scan(let id): ScanDetailView(scanID: id)
                }
            }
        }
        .fullScreenCover(isPresented: $isPresentingScan) {
            ScanFlowView { savedRecord in
                if let savedRecord { app.library.merge(savedRecord) }
                isPresentingScan = false
            }
        }
        .sheet(isPresented: $isPresentingSafety) {
            SafetyPageView()
        }
        .task {
            if !app.library.hasLoadedOnce {
                await app.library.refresh()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(Branding.tagline)
                .font(Theme.Typography.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)
            Text(Branding.productCategory)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var newScanButton: some View {
        Button {
            // Before the cover is presented, not after: if presenting the scan
            // screen is itself what fails, nothing inside it will have run.
            HardwarePhaseRecorder.enter(.openingScanScreen)
            isPresentingScan = true
        } label: {
            Label("New wall scan", systemImage: "viewfinder")
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier(A11y.homeNewScan)
        .accessibilityHint("Starts the preparation checklist for a new scan.")
    }

    /// Reports a hardware step a previous launch did not come back from.
    ///
    /// The camera, AR tracking and the magnetometer cannot run in the Simulator,
    /// so nothing in the test suite reaches the code that drives them. Without
    /// this card, a failure there is silent: the app disappears and there is
    /// nothing on screen afterwards that says what it had been doing.
    private func interruptedCard(_ phase: HardwarePhase) -> some View {
        Card(title: "\(Branding.productName) stopped last time", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("It stopped while \(phase.activityDescription). Nothing you had saved was "
                    + "affected. If it keeps happening, this sentence is the useful part to report.")
                    .font(Theme.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Got it") { app.acknowledgeInterruptedPhase() }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier(A11y.homeDismissInterruption)
            }
        }
    }

    private func capabilityCard(_ block: CapabilityBlock) -> some View {
        Card(title: block.title, systemImage: block.systemImage) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text(block.message)
                    .font(Theme.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                if block.offersSettings {
                    Button("Open Settings") {
                        SystemSettings.open()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var recentScansSection: some View {
        let summaries = app.library.summaries
        Card(title: "Saved scans", systemImage: "clock.arrow.circlepath") {
            if app.library.isLoading && !app.library.hasLoadedOnce {
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView()
                    Text("Loading saved scans\u{2026}")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            } else if summaries.isEmpty && app.library.problems.isEmpty {
                Text("Nothing saved yet. Finish a scan and choose Save to keep it here.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: Theme.Spacing.small) {
                    ForEach(summaries.prefix(3)) { summary in
                        NavigationLink(value: HomeRoute.scan(summary.id)) {
                            ScanSummaryRow(summary: summary)
                        }
                        .buttonStyle(.plain)
                    }
                    if summaries.contains(where: { $0.clusterCount == 0 }) {
                        // A scan that mapped nothing is never presented as an
                        // all-clear, not even as a one-line list summary.
                        Text(SafetyCopy.noAnomalySubtitle)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !app.library.problems.isEmpty {
                        Text("\(app.library.problems.count) saved file(s) could not be opened. "
                            + "Open all scans to review them.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Palette.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    NavigationLink(value: HomeRoute.history) {
                        Text("All scans (\(summaries.count))")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier(A11y.homeHistory)
                }
            }
        }
    }

    private var toolsSection: some View {
        VStack(spacing: Theme.Spacing.small) {
            NavigationLink(value: HomeRoute.howItWorks) {
                HomeRow(
                    systemImage: "book",
                    title: "How it works",
                    subtitle: "What is measured, and what it cannot tell you"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.homeHowItWorks)

            NavigationLink(value: HomeRoute.diagnostics) {
                HomeRow(
                    systemImage: "waveform.badge.magnifyingglass",
                    title: "Sensor diagnostics",
                    subtitle: "Live sensor readings, recording and export"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.homeDiagnostics)
        }
    }

    private var footer: some View {
        VStack(spacing: Theme.Spacing.hairline) {
            Text("\(Branding.productName) \(Branding.versionDisplayString)")
            Text("Algorithm \(AlgorithmVersion.current)")
            Text(Branding.organizationName)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.medium)
    }
}

/// Navigation destinations reachable from Home.
enum HomeRoute: Hashable {
    case history
    case diagnostics
    case settings
    case howItWorks
    case scan(UUID)
}

/// A tappable row on the home screen.
struct HomeRow: View {
    var systemImage: String
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typography.cardTitle)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(Theme.Spacing.medium)
        .frame(minHeight: Theme.minimumTouchTarget)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One saved scan, as shown in a list.
struct ScanSummaryRow: View {
    let summary: ScanSummary

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(summary.name)
                        .font(Theme.Typography.cardTitle)
                    if summary.isSimulated {
                        Text("SIMULATED")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.25), in: Capsule())
                    }
                }
                Text(Format.scanDate.string(from: summary.createdAt))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: Theme.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.name). \(Format.scanDate.string(from: summary.createdAt)). \(detail)")
    }

    private var detail: String {
        if summary.clusterCount == 0 {
            return SafetyCopy.noAnomalyHeadline
        }
        let noun = summary.clusterCount == 1 ? "anomaly" : "anomalies"
        return "\(summary.clusterCount) magnetic \(noun), \(summary.repeatedClusterCount) repeated"
            + " \u{00B7} \(Format.duration(summary.duration))"
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment.preview())
}

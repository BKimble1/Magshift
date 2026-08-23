import SwiftUI

/// The permanent safety and limitations page.
///
/// Reachable from Settings, from the home screen banner, from the scan HUD and
/// from every saved scan. Its content is the same everywhere because it is all
/// drawn from `SafetyCopy`.
struct SafetyPageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var app
    /// Set when the page is pushed rather than presented, so it does not offer a
    /// redundant Close button.
    var isEmbedded = false

    var body: some View {
        Group {
            if isEmbedded {
                content
            } else {
                NavigationStack {
                    content
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Close") { dismiss() }
                                    .accessibilityIdentifier(A11y.safetyClose)
                            }
                        }
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Text(SafetyCopy.canonicalStatement)
                    .font(Theme.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)

                Card(title: SafetyCopy.beforeYouDrillTitle, systemImage: "exclamationmark.triangle") {
                    BulletList(items: SafetyCopy.beforeYouDrillPoints)
                }

                section("What it measures", SafetyCopy.whatItMeasures)
                section("What it cannot determine", SafetyCopy.whatItCannotDo)
                section("Wall materials", SafetyCopy.whyMaterialsMatter)
                section("Wiring", SafetyCopy.aboutWiring)
                section("A quiet reading", SafetyCopy.absenceIsNotEvidence)
                section("Magnetic accessories", SafetyCopy.whyReadingsGetDistorted)
                section("What confidence means", SafetyCopy.confidenceMeaning)
                section("What this app will never ask you to do", SafetyCopy.neverDoThis)

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    NoAnomalyStatement()
                }
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .fill(Palette.caution.opacity(0.12))
                )

                if let acknowledgedAt = app.preferences.acknowledgedAt {
                    Text("You acknowledged these limitations on "
                        + "\(Format.scanDate.string(from: acknowledgedAt)) "
                        + "(version \(app.preferences.acknowledgedVersion)).")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .navigationTitle("Safety & limitations")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.safetyPage)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(title)
                .font(Theme.Typography.cardTitle)
            Text(body)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The "How it works" explainer reached from Home.
struct HowItWorksView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Text(Branding.productCategory)
                    .font(Theme.Typography.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)

                step(1, "Map the wall", SafetyCopy.howARMappingWorks)
                step(2, "Lock one wall",
                     "You choose the surface. Once locked, \(Branding.productName) stays on it and will "
                        + "not quietly switch to another wall part-way through a scan.")
                step(3, "Calibrate",
                     "Hold the phone still for a few seconds. \(Branding.productName) measures the quiet "
                        + "field where you are standing and how much it naturally wobbles. Everything after "
                        + "this is measured relative to that, because there is no universal number that "
                        + "means \"metal\".")
                step(4, "Scan", SafetyCopy.howToScan)
                step(5, "Repeat a pass",
                     "A reading measured once is marked Unconfirmed no matter how large it is. Scan the "
                        + "same area again and readings that reappear in the same place become Repeated.")
                step(6, "Review and save",
                     "You get a flat map of the wall, the numbers behind every mark, and files you can "
                        + "export. Nothing leaves your iPhone unless you share it yourself.")

                Card(title: "What the marks mean", systemImage: "circle.grid.cross") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("Every mark is labelled \(SafetyCopy.anomalyLabel). That is the honest "
                            + "description of what was measured.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text(SafetyCopy.confidenceMeaning)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.Typography.body)
                }

                SafetyStatementCard()
            }
            .padding(Theme.Spacing.medium)
        }
        .navigationTitle("How it works")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Text("\(number)")
                .font(Theme.Typography.cardTitle)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.accent.opacity(0.18)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(title).font(Theme.Typography.cardTitle)
                Text(body)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Safety") {
    SafetyPageView()
        .environment(AppEnvironment.preview())
}

#Preview("How it works") {
    NavigationStack { HowItWorksView() }
}

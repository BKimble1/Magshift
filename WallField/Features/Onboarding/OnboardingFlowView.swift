import SwiftUI

/// One page of onboarding.
struct OnboardingPage: Identifiable, Hashable {
    var id: String { title }
    var systemImage: String
    var title: String
    var body: String
    var points: [String]

    static let pages: [OnboardingPage] = [
        OnboardingPage(
            systemImage: "waveform.path.ecg",
            title: "What \(Branding.productName) measures",
            body: SafetyCopy.whatItMeasures,
            points: []
        ),
        OnboardingPage(
            systemImage: "eye.slash",
            title: "What it cannot determine",
            body: SafetyCopy.whatItCannotDo,
            points: [
                SafetyCopy.whyMaterialsMatter,
                SafetyCopy.aboutWiring,
                SafetyCopy.absenceIsNotEvidence,
            ]
        ),
        OnboardingPage(
            systemImage: "magnet",
            title: "Magnets ruin readings",
            body: SafetyCopy.whyReadingsGetDistorted,
            points: []
        ),
        OnboardingPage(
            systemImage: "arkit",
            title: "How wall mapping works",
            body: SafetyCopy.howARMappingWorks,
            points: []
        ),
        OnboardingPage(
            systemImage: "hand.draw",
            title: "How to scan",
            body: SafetyCopy.howToScan,
            points: []
        ),
    ]
}

/// First-run flow, and the flow shown again when the safety wording changes.
///
/// The last page is not a summary: it is a decision the user has to make, with
/// an explicit control they must operate. Tapping through cannot accept it.
struct OnboardingFlowView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var pageIndex = 0
    @State private var hasAcknowledged = false

    private var pages: [OnboardingPage] { OnboardingPage.pages }
    private var isOnAcknowledgement: Bool { pageIndex >= pages.count }

    var body: some View {
        VStack(spacing: 0) {
            if app.runtimeMode.isSimulated {
                SimulatedDataBanner()
            }
            if app.preferences.isReacknowledging, !isOnAcknowledgement {
                revisedNotice
            }

            TabView(selection: $pageIndex) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
                acknowledgementPage
                    .tag(pages.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
                .padding(Theme.Spacing.medium)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var revisedNotice: some View {
        Text("The safety information has been updated. Please read it again.")
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.top, Theme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

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
        }
    }

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
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(page.title)
                    .font(Theme.Typography.screenTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(page.body)
                    .font(Theme.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                if !page.points.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        ForEach(page.points, id: \.self) { point in
                            Text(point)
                                .font(Theme.Typography.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.extraLarge)
        }
    }
}

#Preview {
    OnboardingFlowView()
        .environment(AppEnvironment.preview())
}

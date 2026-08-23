import SwiftUI

// MARK: - Buttons

/// The primary call to action. One per screen.
struct PrimaryButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.cardTitle)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.minimumTouchTarget)
            .padding(.horizontal, Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(isDestructive ? Color.red : Palette.accent)
            )
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }
}

/// Secondary actions: outlined, never coloured as a success state.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.cardTitle)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.minimumTouchTarget)
            .padding(.horizontal, Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            )
            .foregroundStyle(Color.primary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }
}

/// Compact control used over the camera feed.
struct HUDButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(minHeight: Theme.minimumTouchTarget)
            .frame(minWidth: Theme.minimumTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(isProminent ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Theme.hudMaterial))
            )
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }
}

// MARK: - Containers

/// A grouped block of content.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    if let systemImage {
                        Image(systemName: systemImage)
                    }
                }
                .font(Theme.Typography.cardTitle)
                .labelStyle(.titleAndIcon)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

/// A labelled value, used for readouts and summaries.
struct StatTile: View {
    var label: String
    var value: String
    var caption: String? = nil
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            HStack(spacing: Theme.Spacing.tight) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
                Text(label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(Theme.Typography.readoutSmall)
            if let caption {
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(caption.map { ". \($0)" } ?? "")")
    }
}

/// A list of plain-language points.
struct BulletList: View {
    var items: [String]
    var systemImage = "circle.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Image(systemName: systemImage)
                        .font(.system(size: 6))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(Theme.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Safety

/// The compact reminder shown on the home screen and the scan HUD.
///
/// Deliberately calm: amber, small, never an alarm. An app that shouts loses the
/// attention it needs for the one message that matters.
struct SafetyReminderBar: View {
    var text: String = SafetyCopy.compactStatement
    var action: (() -> Void)? = nil

    var body: some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Palette.caution)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if action != nil {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Palette.caution.opacity(0.12))
        )

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11y.safetyBanner)
                .accessibilityHint("Opens safety and limitations.")
        } else {
            content
        }
    }
}

/// The full canonical statement. Used in onboarding, review and the safety page.
struct SafetyStatementCard: View {
    var body: some View {
        Card(title: "What this means", systemImage: "exclamationmark.triangle") {
            Text(SafetyCopy.canonicalStatement)
                .font(Theme.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown wherever a scan produced no clusters.
///
/// Never green, never "clear", and the qualifying sentence is not optional --
/// it is part of the component so it cannot be omitted at a call site.
struct NoAnomalyStatement: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(SafetyCopy.noAnomalyHeadline)
                .font(Theme.Typography.cardTitle)
            Text(SafetyCopy.noAnomalySubtitle)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11y.reviewNoAnomalies)
    }
}

/// Persistent banner shown on every screen driven by simulated data.
struct SimulatedDataBanner: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: "testtube.2")
                .accessibilityHidden(true)
            Text(RuntimeMode.simulatedBannerText)
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, Theme.Spacing.tight)
        .padding(.horizontal, Theme.Spacing.small)
        .frame(maxWidth: .infinity)
        .background(Color.purple.opacity(0.22))
        .foregroundStyle(Color.primary)
        .accessibilityIdentifier(A11y.homeSimulatedBanner)
    }
}

// MARK: - States

/// Shown when a list has nothing in it yet.
struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 320)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity)
    }
}

/// Shown when something is blocked and the user can do something about it.
struct BlockedStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var primaryTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Palette.caution)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Theme.Spacing.small) {
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(PrimaryButtonStyle())
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(maxWidth: 360)
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Measurement display

/// The strength meter on the scan HUD.
///
/// Shows how far the current reading is from baseline relative to the threshold,
/// with a tick at the threshold itself. Restrained on purpose: it is a gauge, not
/// a dial that swings dramatically.
struct StrengthMeter: View {
    /// `0...1`, already normalised by the caller.
    var level: Double
    /// Where the detection threshold sits on the same scale.
    var thresholdFraction: Double
    var band: AnomalyStrengthBand

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                Capsule()
                    .fill(Palette.color(forBand: band))
                    .frame(width: proxy.size.width * min(max(level, 0), 1))
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 2)
                    .offset(x: proxy.size.width * min(max(thresholdFraction, 0), 1) - 1)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// The AR legend. Describes the measurement, never an object type.
struct HeatMapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(SafetyCopy.legendTitle)
                .font(.caption.weight(.semibold))
            ForEach(AnomalyStrengthBand.allCases, id: \.self) { band in
                HStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: band.symbolName)
                        .foregroundStyle(Palette.color(forBand: band))
                        .accessibilityHidden(true)
                    Text(band.displayName)
                        .font(.caption)
                }
            }
            Divider()
            ForEach(ClusterConfidence.allCases, id: \.self) { confidence in
                HStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: confidence.symbolName)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(confidence.displayName)
                        .font(.caption)
                }
            }
        }
        .padding(Theme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.hudMaterial)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Legend. \(SafetyCopy.legendTitle).")
    }
}

/// The centre-screen crosshair.
struct Crosshair: View {
    var isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(isActive ? 0.95 : 0.45), lineWidth: 2)
                .frame(width: 30, height: 30)
            Circle()
                .fill(Color.white.opacity(isActive ? 0.95 : 0.45))
                .frame(width: 4, height: 4)
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .accessibilityHidden(true)
    }
}

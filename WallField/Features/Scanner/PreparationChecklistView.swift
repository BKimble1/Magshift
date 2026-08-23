import SwiftUI

/// The checklist shown before any hardware starts.
///
/// Nothing is powered up while this is on screen: the camera and the
/// magnetometer only start when the user leaves this page. Reading a checklist
/// should not drain a battery.
struct PreparationChecklistView: View {
    var onContinue: () -> Void
    var onCancel: () -> Void

    @State private var checked: Set<Int> = []

    private var items: [String] { SafetyCopy.preparationChecklist }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        Text("Before you scan")
                            .font(Theme.Typography.screenTitle)
                        Text("Tap each item as you do it. Magnets and loose metal near the phone are the "
                            + "single biggest cause of misleading readings.")
                            .font(Theme.Typography.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: Theme.Spacing.small) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            checklistRow(index: index, text: item)
                        }
                    }

                    Card(title: "How to move", systemImage: "hand.draw") {
                        Text(SafetyCopy.howToScan)
                            .font(Theme.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SafetyStatementCard()
                }
                .padding(Theme.Spacing.medium)
            }
            .navigationTitle("Scan preparation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Theme.Spacing.small) {
                    Button("Start mapping the wall", action: onContinue)
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier(A11y.prepChecklistContinue)
                    Text("The camera and sensors start on the next screen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Spacing.medium)
                .background(.bar)
            }
        }
    }

    private func checklistRow(index: Int, text: String) -> some View {
        let isChecked = checked.contains(index)
        return Button {
            if isChecked { checked.remove(index) } else { checked.insert(index) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? Palette.accent : Color.secondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(Theme.Typography.body)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.medium)
            .frame(minHeight: Theme.minimumTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChecked ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(text)
        .accessibilityValue(isChecked ? "Done" : "Not done")
    }
}

#Preview {
    PreparationChecklistView(onContinue: {}, onCancel: {})
}

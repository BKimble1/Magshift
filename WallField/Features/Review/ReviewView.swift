import SwiftUI

/// End-of-scan review. Nothing is written to disk until Save is tapped.
struct ReviewView: View {
    @Bindable var coordinator: ScanCoordinator
    var onDone: (ScanRecord?) -> Void

    @Environment(AppEnvironment.self) private var app
    @State private var name = ""
    @State private var notes = ""
    @State private var tagText = ""
    @State private var isPresentingSafety = false
    @State private var isConfirmingDiscard = false
    @State private var exporter = ExportController()
    @State private var hasSaved = false

    private var record: ScanRecord? { coordinator.draftRecord }

    var body: some View {
        NavigationStack {
            Group {
                if let record {
                    content(for: record)
                } else {
                    EmptyStateView(
                        systemImage: "questionmark.circle",
                        title: "Nothing to review",
                        message: "This scan ended before any measurements were made.",
                        actionTitle: "Close",
                        action: { onDone(nil) }
                    )
                }
            }
            .navigationTitle("Review scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Discard", role: .destructive) { isConfirmingDiscard = true }
                        .accessibilityIdentifier(A11y.reviewDiscard)
                }
            }
        }
        .sheet(isPresented: $isPresentingSafety) { SafetyPageView() }
        .sheet(isPresented: Binding(
            get: { exporter.isPresentingShareSheet },
            set: { exporter.isPresentingShareSheet = $0 }
        )) {
            ShareSheet(urls: exporter.urls) { exporter.cleanUp() }
        }
        .confirmationDialog(
            "Discard this scan?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                coordinator.discardDraft()
                onDone(nil)
            }
            Button("Keep reviewing", role: .cancel) {}
        } message: {
            Text("Everything measured in this scan will be lost.")
        }
        .onAppear {
            if name.isEmpty { name = record?.displayName ?? app.preferences.nextScanName() }
        }
    }

    private func content(for record: ScanRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Card(title: "Name and notes", systemImage: "square.and.pencil") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        TextField("Scan name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier(A11y.reviewName)
                        TextField("Notes (optional)", text: $notes, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier(A11y.reviewNotes)
                        TextField("Validation tags, comma separated (optional)", text: $tagText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityHint("Used when comparing scans against known ground truth.")
                    }
                }

                ScanSummaryContent(record: record) { isPresentingSafety = true }

                if let error = coordinator.saveError {
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = exporter.error {
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Spacing.small) {
                Button {
                    Task {
                        let saved = await coordinator.save(name: name, notes: notes, tags: parsedTags)
                        if saved {
                            hasSaved = true
                            onDone(coordinator.draftRecord)
                        }
                    }
                } label: {
                    if coordinator.isSaving {
                        ProgressView()
                    } else {
                        Text(hasSaved ? "Saved" : "Save scan")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(coordinator.isSaving)
                .accessibilityIdentifier(A11y.reviewSave)

                Button {
                    Task { await exporter.prepare(record: prepared(record)) }
                } label: {
                    if exporter.isPreparing {
                        ProgressView()
                    } else {
                        Label("Export CSV and JSON", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(exporter.isPreparing)
                .accessibilityIdentifier(A11y.reviewExport)
            }
            .padding(Theme.Spacing.medium)
            .background(.bar)
        }
    }

    /// The record with the user's current edits applied, so an export taken
    /// before saving still carries the name and notes on screen.
    private func prepared(_ record: ScanRecord) -> ScanRecord {
        var copy = record
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.notes = notes
        copy.validationTags = parsedTags
        return copy
    }

    private var parsedTags: [String] {
        tagText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

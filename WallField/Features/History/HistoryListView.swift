import SwiftUI

/// Every saved scan, plus any file that could not be opened.
struct HistoryListView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var pendingDeletion: ScanSummary?
    @State private var pendingProblemDeletion: ScanFileProblem?

    var body: some View {
        Group {
            if app.library.isLoading && !app.library.hasLoadedOnce {
                ProgressView("Loading saved scans\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.library.isEmpty {
                EmptyStateView(
                    systemImage: "tray",
                    title: "No saved scans",
                    message: "Finish a scan and choose Save to keep it here. Saved scans stay on this "
                        + "iPhone; nothing is uploaded."
                )
                .accessibilityIdentifier(A11y.historyEmpty)
            } else {
                list
            }
        }
        .navigationTitle("Saved scans")
        .navigationBarTitleDisplayMode(.inline)
        .task { await app.library.refresh() }
        .refreshable { await app.library.refresh() }
        .confirmationDialog(
            "Delete this scan?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion {
                    let id = pendingDeletion.id
                    Task { await app.library.delete(id: id) }
                }
                pendingDeletion = nil
            }
            .accessibilityIdentifier(A11y.historyConfirmDelete)
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("\(pendingDeletion?.name ?? "This scan") will be removed from this iPhone. "
                + "This cannot be undone.")
        }
        .confirmationDialog(
            "Delete this file?",
            isPresented: Binding(
                get: { pendingProblemDeletion != nil },
                set: { if !$0 { pendingProblemDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete file", role: .destructive) {
                if let name = pendingProblemDeletion?.id {
                    Task { await app.library.deleteProblemFile(named: name) }
                }
                pendingProblemDeletion = nil
            }
            Button("Keep it", role: .cancel) { pendingProblemDeletion = nil }
        } message: {
            Text("This file could not be opened as a scan. Deleting it cannot be undone.")
        }
    }

    private var list: some View {
        List {
            if let error = app.library.actionError {
                Section {
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red)
                }
            }

            if !app.library.summaries.isEmpty {
                Section {
                    ForEach(app.library.summaries) { summary in
                        NavigationLink(value: HomeRoute.scan(summary.id)) {
                            ScanSummaryRow(summary: summary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                pendingDeletion = summary
                            }
                            .accessibilityIdentifier(A11y.historyDelete)
                        }
                    }
                } header: {
                    Text("\(app.library.summaries.count) scan"
                        + "\(app.library.summaries.count == 1 ? "" : "s")")
                } footer: {
                    if app.library.summaries.contains(where: { $0.clusterCount == 0 }) {
                        Text("\(SafetyCopy.compactStatement) \(SafetyCopy.noAnomalySubtitle)")
                    } else {
                        Text(SafetyCopy.compactStatement)
                    }
                }
            }

            if !app.library.problems.isEmpty {
                Section("Files that could not be opened") {
                    ForEach(app.library.problems) { problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.kind.headline)
                                .font(Theme.Typography.cardTitle)
                            Text(problem.kind.detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(problem.id)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, Theme.Spacing.hairline)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                pendingProblemDeletion = problem
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier(A11y.historyList)
    }
}

/// A saved scan, opened from history.
struct ScanDetailView: View {
    let scanID: UUID
    @Environment(AppEnvironment.self) private var app
    @State private var isPresentingSafety = false
    @State private var isConfirmingDelete = false
    @State private var exporter = ExportController()
    @Environment(\.dismiss) private var dismiss

    private var record: ScanRecord? { app.library.record(id: scanID) }

    var body: some View {
        Group {
            if let record {
                ScrollView {
                    ScanSummaryContent(record: record) { isPresentingSafety = true }
                        .padding(Theme.Spacing.medium)
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        Task { await exporter.prepare(record: record) }
                    } label: {
                        if exporter.isPreparing {
                            ProgressView()
                        } else {
                            Label("Export CSV and JSON", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(exporter.isPreparing)
                    // On the control, not on the padding and material around it,
                    // which is a container rather than a button. Review's copy of
                    // this button does the same and is found; this one was not.
                    .accessibilityIdentifier(A11y.reviewExport)
                    .padding(Theme.Spacing.medium)
                    .background(.bar)
                }
                .navigationTitle(record.displayName)
            } else {
                EmptyStateView(
                    systemImage: "questionmark.folder",
                    title: "Scan not found",
                    message: "This scan is no longer on this iPhone."
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete scan")
                .accessibilityIdentifier(A11y.historyDelete)
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
            "Delete this scan?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await app.library.delete(id: scanID)
                    dismiss()
                }
            }
            .accessibilityIdentifier(A11y.historyConfirmDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This scan will be removed from this iPhone. This cannot be undone.")
        }
    }
}

#Preview {
    NavigationStack { HistoryListView() }
        .environment(AppEnvironment.preview())
}

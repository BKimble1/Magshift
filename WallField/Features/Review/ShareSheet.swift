import SwiftUI
import UIKit

/// Native share sheet for exported files.
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    /// Called when the sheet goes away, so the temporary export directory can be
    /// cleaned up rather than left in the container.
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onDismiss()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Prepares export files off the main actor and presents them.
///
/// CSV and JSON generation walks every stored measurement, which can be
/// thousands of rows, so it never runs on the main actor.
@MainActor
@Observable
final class ExportController {
    private(set) var isPreparing = false
    private(set) var urls: [URL] = []
    private(set) var error: String?
    private var temporaryDirectory: URL?

    var isPresentingShareSheet: Bool {
        get { !urls.isEmpty }
        set { if !newValue { cleanUp() } }
    }

    func prepare(record: ScanRecord) async {
        isPreparing = true
        error = nil
        defer { isPreparing = false }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let files = try ScanExporter.files(for: record)
                return try ScanExporter.writeToTemporaryDirectory(files)
            }.value
            temporaryDirectory = prepared.directory
            urls = prepared.urls
        } catch {
            self.error = "The export could not be prepared. \(error.localizedDescription)"
        }
    }

    func prepareDiagnostics(run: DiagnosticRun) async {
        isPreparing = true
        error = nil
        defer { isPreparing = false }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let files = try DiagnosticsExporter.files(for: run)
                return try ScanExporter.writeToTemporaryDirectory(files)
            }.value
            temporaryDirectory = prepared.directory
            urls = prepared.urls
        } catch {
            self.error = "The export could not be prepared. \(error.localizedDescription)"
        }
    }

    func cleanUp() {
        urls = []
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }
}

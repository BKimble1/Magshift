import Foundation
import Observation

/// Observable view of everything the scan store holds.
///
/// One instance is shared by Home and History so a deletion in one is reflected
/// in the other with no notification plumbing and no chance of the two
/// disagreeing about what exists.
@MainActor
@Observable
final class ScanLibrary {
    private let store: any ScanStoring

    private(set) var records: [ScanRecord] = []
    private(set) var problems: [ScanFileProblem] = []
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var actionError: String?

    init(store: any ScanStoring) {
        self.store = store
    }

    var summaries: [ScanSummary] {
        records.map(ScanSummary.init(record:))
    }

    var isEmpty: Bool { records.isEmpty && problems.isEmpty }

    func record(id: UUID) -> ScanRecord? {
        records.first { $0.id == id }
    }

    func refresh() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        let result = await store.load()
        records = result.records
        problems = result.problems
    }

    func delete(id: UUID) async {
        actionError = nil
        do {
            try await store.delete(id: id)
            records.removeAll { $0.id == id }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func deleteProblemFile(named name: String) async {
        actionError = nil
        do {
            try await store.deleteFile(named: name)
            problems.removeAll { $0.id == name }
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Inserts or replaces a record that was just saved, so Home updates without
    /// a round trip to disk.
    func merge(_ record: ScanRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        records.sort { $0.createdAt > $1.createdAt }
    }

    func deleteAll() async {
        actionError = nil
        do {
            try await store.deleteAll()
            records.removeAll()
            problems.removeAll()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

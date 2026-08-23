import Foundation

/// Stores each scan as one JSON file in Application Support.
///
/// # Why one file per scan
///
/// A single index file is a single point of failure: one bad write loses every
/// scan. One file per scan means damage is contained to the scan it belongs to,
/// the history list is rebuilt by reading the directory (so it cannot drift out
/// of sync with reality), and deleting a scan is a file deletion with nothing
/// left to reconcile.
///
/// Writes go to a temporary file and are then moved into place, so a scan file
/// is never observed half-written -- including when the app is terminated
/// mid-save.
///
/// Application Support is backed up by default, which is what users expect of
/// their own saved scans, and the folder is not user-visible in Files because
/// the app does not enable file sharing.
actor FileScanStore: ScanStoring {
    private let directory: URL
    private let fileManager: FileManager

    /// - Parameter containerDirectory: overridden by tests and UI tests to keep
    ///   them out of the real Application Support folder.
    init(containerDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let base: URL
        if let containerDirectory {
            base = containerDirectory
        } else {
            guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else { throw ScanStoreError.directoryUnavailable }
            base = support.appendingPathComponent("WallField", isDirectory: true)
        }
        self.directory = base.appendingPathComponent("Scans", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - ScanStoring

    func load() async -> ScanLoadResult {
        let decoder = ScanCoding.makeDecoder()
        var records: [ScanRecord] = []
        var problems: [ScanFileProblem] = []

        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in contents where url.pathExtension == "json" {
            let name = url.lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate

            guard let data = try? Data(contentsOf: url) else {
                problems.append(ScanFileProblem(
                    id: name,
                    kind: .unreadable("The file could not be opened."),
                    modifiedAt: modified
                ))
                continue
            }

            if let version = ScanCoding.peekSchemaVersion(in: data),
               version > ScanRecord.currentSchemaVersion {
                problems.append(ScanFileProblem(
                    id: name, kind: .futureVersion(version), modifiedAt: modified
                ))
                continue
            }

            do {
                let record = try decoder.decode(ScanRecord.self, from: data)
                records.append(record.migrated())
            } catch {
                Log.persistence.error("Failed to decode a scan file.")
                problems.append(ScanFileProblem(id: name, kind: .corrupted, modifiedAt: modified))
            }
        }

        records.sort { $0.createdAt > $1.createdAt }
        problems.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        return ScanLoadResult(records: records, problems: problems)
    }

    func save(_ record: ScanRecord) async throws {
        let encoder = ScanCoding.makeEncoder(prettyPrinted: false)
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw ScanStoreError.writeFailed("The scan could not be encoded.")
        }

        let destination = url(for: record.id)
        let temporary = directory.appendingPathComponent(
            "\(record.id.uuidString).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: [.atomic])
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ScanStoreError.writeFailed(error.localizedDescription)
        }
    }

    func delete(id: UUID) async throws {
        let target = url(for: id)
        guard fileManager.fileExists(atPath: target.path) else { throw ScanStoreError.notFound }
        try fileManager.removeItem(at: target)
    }

    func deleteFile(named name: String) async throws {
        // Guard against a crafted name escaping the scans directory.
        guard !name.contains("/"), !name.contains("..") else { throw ScanStoreError.notFound }
        let target = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: target.path) else { throw ScanStoreError.notFound }
        try fileManager.removeItem(at: target)
    }

    func deleteAll() async throws {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}

/// In-memory store for previews, unit tests and UI tests.
actor InMemoryScanStore: ScanStoring {
    private var records: [UUID: ScanRecord] = [:]
    private var problems: [ScanFileProblem]

    init(seed: [ScanRecord] = [], problems: [ScanFileProblem] = []) {
        for record in seed { records[record.id] = record }
        self.problems = problems
    }

    func load() async -> ScanLoadResult {
        ScanLoadResult(
            records: records.values.sorted { $0.createdAt > $1.createdAt },
            problems: problems
        )
    }

    func save(_ record: ScanRecord) async throws {
        records[record.id] = record
    }

    func delete(id: UUID) async throws {
        guard records.removeValue(forKey: id) != nil else { throw ScanStoreError.notFound }
    }

    func deleteFile(named name: String) async throws {
        problems.removeAll { $0.id == name }
    }

    func deleteAll() async throws {
        records.removeAll()
        problems.removeAll()
    }
}

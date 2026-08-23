import Foundation

/// A scan file that could not be turned into a `ScanRecord`.
///
/// Reported rather than silently skipped. A user whose scan file is damaged
/// should be told it exists and be able to delete it, not have it quietly vanish
/// from history.
struct ScanFileProblem: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        /// The file exists but is not valid JSON, or does not decode.
        case corrupted
        /// Written by a newer version of the app. Deliberately not decoded.
        case futureVersion(Int)
        /// The file could not be read at all.
        case unreadable(String)

        var headline: String {
            switch self {
            case .corrupted: return "Damaged scan file"
            case .futureVersion: return "Saved by a newer version"
            case .unreadable: return "Could not be read"
            }
        }

        var detail: String {
            switch self {
            case .corrupted:
                return "This file could not be read as a scan. It has been left in place so nothing is lost; you can delete it here."
            case .futureVersion(let version):
                return "This scan was saved by a newer version of \(Branding.productName) (format \(version)). Update the app to open it."
            case .unreadable(let reason):
                return reason
            }
        }
    }

    /// The file name, which is also the identity used to delete it.
    var id: String
    var kind: Kind
    var modifiedAt: Date?
}

/// Everything a load attempt produced.
struct ScanLoadResult: Sendable {
    var records: [ScanRecord]
    var problems: [ScanFileProblem]

    static let empty = ScanLoadResult(records: [], problems: [])
}

/// Local persistence for scans.
///
/// Deliberately narrow, and deliberately without a networking or account
/// concept: version 1 is entirely on-device and this protocol is the whole of
/// its data layer.
protocol ScanStoring: Sendable {
    /// Loads every scan, newest first, along with any files that failed.
    func load() async -> ScanLoadResult
    /// Writes a record, replacing any existing record with the same identifier.
    func save(_ record: ScanRecord) async throws
    /// Deletes one scan.
    func delete(id: UUID) async throws
    /// Deletes a file that failed to decode, by its reported file name.
    func deleteFile(named name: String) async throws
    /// Removes everything. Used by the developer tools and by UI tests.
    func deleteAll() async throws
}

/// Errors the store can raise.
enum ScanStoreError: LocalizedError {
    case directoryUnavailable
    case notFound
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable:
            return "\(Branding.productName) could not open its storage folder."
        case .notFound:
            return "That scan no longer exists."
        case .writeFailed(let reason):
            return "The scan could not be saved. \(reason)"
        }
    }
}

/// JSON coders shared by the store and the exporter.
///
/// Dates are written as ISO-8601 with fractional seconds: readable in an
/// exported file, and precise to the millisecond, which is far finer than
/// anything the scan metadata needs.
enum ScanCoding {
    static func makeEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Format.iso8601.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Format.iso8601.date(from: raw) { return date }
            // Tolerate a date written without fractional seconds, so a file
            // produced by any reasonable ISO-8601 writer still opens.
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let date = fallback.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date, found \(raw)."
            )
        }
        return decoder
    }

    /// Reads only `schemaVersion`, so a record from a newer build can be
    /// identified without attempting to decode fields that may not exist yet.
    static func peekSchemaVersion(in data: Data) -> Int? {
        struct VersionProbe: Decodable { var schemaVersion: Int }
        return try? JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
    }
}

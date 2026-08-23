import Foundation

/// One file produced by an export.
struct ExportFile: Sendable, Hashable, Identifiable {
    var id: String { fileName }
    var fileName: String
    var contents: Data

    var byteCount: Int { contents.count }
}

/// Turns a saved scan into files a person or a spreadsheet can read.
///
/// Pure and free of framework dependencies so it can run off the main actor and
/// be tested byte-for-byte. Every file it produces carries
/// `SafetyCopy.exportHeader`, so the limitation travels with the data even when
/// the file is opened months later on somebody else's machine.
enum ScanExporter {

    /// Format identifier written into the JSON envelope. Increment when the
    /// envelope's shape changes so downstream tooling can branch on it.
    static let jsonFormatIdentifier = "wallfield.scan.v1"

    /// Every file for one scan: two CSVs and one JSON.
    static func files(for record: ScanRecord, exportedAt: Date = Date()) throws -> [ExportFile] {
        let slug = Format.fileSlug(record.displayName)
        return [
            ExportFile(
                fileName: "\(slug)-measurements.csv",
                contents: Data(measurementsCSV(for: record).utf8)
            ),
            ExportFile(
                fileName: "\(slug)-clusters.csv",
                contents: Data(clustersCSV(for: record).utf8)
            ),
            ExportFile(
                fileName: "\(slug).json",
                contents: try json(for: record, exportedAt: exportedAt)
            ),
        ]
    }

    // MARK: - CSV

    /// Lines prefixed with `#` before the header row. Spreadsheet apps show them
    /// as ordinary rows, which is the point: the reader sees the limitation
    /// before the numbers.
    static func csvPreamble(for record: ScanRecord) -> String {
        var lines = SafetyCopy.exportHeader.split(separator: "\n").map { "# \($0)" }
        lines.append("# Scan: \(record.displayName)")
        lines.append("# Recorded: \(Format.iso8601.string(from: record.createdAt))")
        lines.append("# App version: \(record.appVersion)   Algorithm version: \(record.algorithmVersion)")
        lines.append("# Device model: \(record.device.model)   OS: \(record.device.systemVersion)")
        lines.append("# Sensitivity: \(record.sensitivity.displayName)")
        lines.append("# Baseline: \(Format.decimal(record.calibration.baselineMagnitude, decimals: 3)) uT   "
            + "Sigma: \(Format.decimal(record.calibration.sigma, decimals: 4)) uT")
        if record.isSimulated {
            lines.append("# SIMULATED DATA - not a measurement of a real wall.")
        }
        lines.append("# All field values are microtesla (uT). All positions are metres.")
        lines.append("# 'Magnetic anomaly' means a measured change in the magnetic field. "
            + "It does not identify an object.")
        return lines.joined(separator: "\n") + "\n"
    }

    static let measurementColumns = [
        "timestamp_monotonic_s", "elapsed_s",
        "field_x_uT", "field_y_uT", "field_z_uT", "magnitude_uT",
        "delta_uT", "robust_z", "score", "gradient_uT_per_s", "persistence",
        "calibration_accuracy", "source",
        "timing_error_ms", "tracking_state", "raycast_quality",
        "wall_x_m", "wall_y_m",
        "world_x_m", "world_y_m", "world_z_m",
        "wall_distance_m", "camera_speed_m_per_s",
        "pass_index", "cluster_id",
    ]

    static func measurementsCSV(for record: ScanRecord) -> String {
        var output = csvPreamble(for: record)
        output += measurementColumns.joined(separator: ",") + "\n"
        for measurement in record.measurements {
            let fields: [String] = [
                Format.decimal(measurement.timestamp, decimals: 4),
                Format.decimal(measurement.elapsed, decimals: 4),
                Format.decimal(Double(measurement.field.x), decimals: 4),
                Format.decimal(Double(measurement.field.y), decimals: 4),
                Format.decimal(Double(measurement.field.z), decimals: 4),
                Format.decimal(measurement.magnitude, decimals: 4),
                Format.decimal(measurement.delta, decimals: 4),
                Format.decimal(measurement.robustZScore, decimals: 3),
                Format.decimal(measurement.score, decimals: 3),
                Format.decimal(measurement.gradient, decimals: 3),
                String(measurement.persistence),
                measurement.accuracy.displayName,
                measurement.source.rawValue,
                Format.decimal(measurement.timingError * 1000, decimals: 2),
                trackingDescription(measurement.trackingQuality),
                measurement.raycastQuality.rawValue,
                Format.decimal(measurement.wallPoint.x, decimals: 4),
                Format.decimal(measurement.wallPoint.y, decimals: 4),
                Format.decimal(Double(measurement.worldPosition.x), decimals: 4),
                Format.decimal(Double(measurement.worldPosition.y), decimals: 4),
                Format.decimal(Double(measurement.worldPosition.z), decimals: 4),
                Format.decimal(measurement.wallDistance, decimals: 4),
                Format.decimal(measurement.cameraSpeed, decimals: 4),
                String(measurement.passIndex),
                measurement.clusterID.uuidString,
            ]
            output += fields.map(escape).joined(separator: ",") + "\n"
        }
        return output
    }

    static let clusterColumns = [
        "cluster_id", "label", "wall_x_m", "wall_y_m",
        "peak_delta_uT", "peak_robust_z", "peak_score", "strength_band",
        "confidence", "sample_count", "pass_count", "pass_indices",
        "first_seen", "last_seen",
        "best_raycast_quality", "worst_timing_error_ms", "polarity",
    ]

    static func clustersCSV(for record: ScanRecord) -> String {
        var output = csvPreamble(for: record)
        output += clusterColumns.joined(separator: ",") + "\n"
        for cluster in record.clusters {
            let fields: [String] = [
                cluster.id.uuidString,
                cluster.label,
                Format.decimal(cluster.wallPoint.x, decimals: 4),
                Format.decimal(cluster.wallPoint.y, decimals: 4),
                Format.decimal(cluster.peakDelta, decimals: 4),
                Format.decimal(cluster.peakZScore, decimals: 3),
                Format.decimal(cluster.peakScore, decimals: 3),
                cluster.strengthBand.rawValue,
                cluster.confidence.rawValue,
                String(cluster.sampleCount),
                String(cluster.passCount),
                cluster.passIndices.map(String.init).joined(separator: " "),
                Format.iso8601.string(from: cluster.firstSeen),
                Format.iso8601.string(from: cluster.lastSeen),
                cluster.bestRaycastQuality.rawValue,
                Format.decimal(cluster.worstTimingError * 1000, decimals: 2),
                cluster.polarity.rawValue,
            ]
            output += fields.map(escape).joined(separator: ",") + "\n"
        }
        return output
    }

    /// RFC 4180 quoting: wrap in quotes when the value contains a comma, quote,
    /// carriage return or newline, and double any embedded quotes.
    static func escape(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func trackingDescription(_ quality: TrackingQuality) -> String {
        switch quality {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited(let reason): return "limited_\(reason.rawValue)"
        }
    }

    // MARK: - JSON

    /// Versioned envelope around the full record.
    struct Envelope: Codable, Sendable {
        var format: String
        var exportedAt: Date
        var notice: String
        var appVersion: String
        var algorithmVersion: String
        var scan: ScanRecord
    }

    static func json(for record: ScanRecord, exportedAt: Date = Date()) throws -> Data {
        let envelope = Envelope(
            format: jsonFormatIdentifier,
            exportedAt: exportedAt,
            notice: SafetyCopy.canonicalStatement,
            appVersion: record.appVersion,
            algorithmVersion: record.algorithmVersion,
            scan: record
        )
        return try ScanCoding.makeEncoder(prettyPrinted: true).encode(envelope)
    }

    // MARK: - Writing to disk for the share sheet

    /// Writes the export files into a fresh temporary directory and returns their
    /// URLs, ready to hand to `UIActivityViewController`.
    ///
    /// A per-export subdirectory keeps two exports of scans with the same name
    /// from overwriting each other, and lets the whole export be cleaned up in
    /// one call.
    static func writeToTemporaryDirectory(
        _ files: [ExportFile],
        fileManager: FileManager = .default
    ) throws -> (directory: URL, urls: [URL]) {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("WallFieldExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for file in files {
            let url = directory.appendingPathComponent(file.fileName)
            try file.contents.write(to: url, options: [.atomic])
            urls.append(url)
        }
        return (directory, urls)
    }
}

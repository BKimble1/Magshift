import Foundation

/// Turns a diagnostic recording into CSV and JSON.
///
/// Kept separate from `ScanExporter` because the two files answer different
/// questions: a scan export describes mapped anomalies, a diagnostic export is
/// the raw sensor trace needed to test whether the hardware premise holds at all.
enum DiagnosticsExporter {

    static let jsonFormatIdentifier = "wallfield.diagnostics.v1"

    static let columns = [
        "elapsed_s", "timestamp_monotonic_s",
        "x_uT", "y_uT", "z_uT", "magnitude_uT", "smoothed_uT",
        "baseline_uT", "delta_uT", "robust_z", "sigma_uT",
        "gradient_uT_per_s", "persistence", "detector_state",
        "calibration_accuracy", "sample_interval_s", "source",
        "user_acceleration_g", "rotation_rate_rad_per_s",
        "tracking_state", "raycast_distance_m",
    ]

    static func csv(for run: DiagnosticRun) -> String {
        var output = preamble(for: run)
        output += columns.joined(separator: ",") + "\n"
        for sample in run.samples {
            let fields: [String] = [
                Format.decimal(sample.elapsed, decimals: 4),
                Format.decimal(sample.timestamp, decimals: 4),
                Format.decimal(sample.x, decimals: 4),
                Format.decimal(sample.y, decimals: 4),
                Format.decimal(sample.z, decimals: 4),
                Format.decimal(sample.magnitude, decimals: 4),
                Format.decimal(sample.smoothedMagnitude, decimals: 4),
                Format.decimal(sample.baseline, decimals: 4),
                Format.decimal(sample.delta, decimals: 4),
                Format.decimal(sample.robustZScore, decimals: 3),
                Format.decimal(sample.sigma, decimals: 4),
                Format.decimal(sample.gradient, decimals: 3),
                String(sample.persistence),
                sample.detectorState.rawValue,
                sample.accuracy.displayName,
                Format.decimal(sample.interval, decimals: 5),
                sample.source.rawValue,
                sample.userAcceleration.map { Format.decimal($0, decimals: 4) } ?? "",
                sample.rotationRate.map { Format.decimal($0, decimals: 4) } ?? "",
                sample.trackingState.map(describe) ?? "",
                sample.raycastDistance.map { Format.decimal($0, decimals: 4) } ?? "",
            ]
            output += fields.map(ScanExporter.escape).joined(separator: ",") + "\n"
        }
        return output
    }

    static func preamble(for run: DiagnosticRun) -> String {
        var lines = SafetyCopy.exportHeader.split(separator: "\n").map { "# \($0)" }
        lines.append("# Diagnostic run: \(run.label)")
        if !run.notes.isEmpty { lines.append("# Notes: \(run.notes.replacingOccurrences(of: "\n", with: " "))") }
        lines.append("# Started: \(Format.iso8601.string(from: run.startedAt))")
        lines.append("# Duration: \(Format.duration(run.duration))   Samples: \(run.samples.count)")
        lines.append("# Requested rate: \(Format.hertz(run.requestedSampleRate))"
            + "   Measured rate: \(Format.hertz(run.measuredSampleRate))")
        if let offset = run.coreMotionClockOffset {
            lines.append("# Observed systemUptime - CoreMotion timestamp: "
                + "\(Format.decimal(offset, decimals: 6)) s")
        }
        lines.append("# Device: \(run.device.model)   OS: \(run.device.systemVersion)")
        lines.append("# App: \(run.appVersion)   Algorithm: \(run.algorithmVersion)")
        if let calibration = run.calibration {
            lines.append("# Baseline: \(Format.decimal(calibration.baselineMagnitude, decimals: 4)) uT"
                + "   Sigma: \(Format.decimal(calibration.sigma, decimals: 5)) uT"
                + "   MAD: \(Format.decimal(calibration.medianAbsoluteDeviation, decimals: 5)) uT")
        } else {
            lines.append("# No baseline calibration was in force for this run.")
        }
        if run.isSimulated {
            lines.append("# SIMULATED DATA - not a measurement of real hardware.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct Envelope: Codable, Sendable {
        var format: String
        var exportedAt: Date
        var notice: String
        var run: DiagnosticRun
    }

    static func json(for run: DiagnosticRun, exportedAt: Date = Date()) throws -> Data {
        let envelope = Envelope(
            format: jsonFormatIdentifier,
            exportedAt: exportedAt,
            notice: SafetyCopy.canonicalStatement,
            run: run
        )
        return try ScanCoding.makeEncoder(prettyPrinted: false).encode(envelope)
    }

    static func files(for run: DiagnosticRun, exportedAt: Date = Date()) throws -> [ExportFile] {
        let slug = Format.fileSlug(run.label, fallback: "diagnostics")
        return [
            ExportFile(fileName: "\(slug)-diagnostics.csv", contents: Data(csv(for: run).utf8)),
            ExportFile(fileName: "\(slug)-diagnostics.json", contents: try json(for: run, exportedAt: exportedAt)),
        ]
    }

    private static func describe(_ quality: TrackingQuality) -> String {
        switch quality {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited(let reason): return "limited_\(reason.rawValue)"
        }
    }
}

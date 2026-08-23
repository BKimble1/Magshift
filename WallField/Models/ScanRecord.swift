import Foundation

/// One accepted measurement, stored so a scan can be re-analysed offline.
struct StoredMeasurement: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    /// Monotonic timestamp of the field sample.
    var timestamp: TimeInterval
    /// Seconds since the scan started, for human-readable exports.
    var elapsed: TimeInterval
    /// Field vector at the moment of detection, µT.
    var field: Vector3
    /// Vector magnitude, µT.
    var magnitude: Double
    /// Signed deviation from the slow baseline, µT.
    var delta: Double
    /// Robust z-score.
    var robustZScore: Double
    /// Normalised score, `0...1`.
    var score: Double
    /// Gradient of the smoothed magnitude, µT/s.
    var gradient: Double
    /// Persistence count at detection.
    var persistence: Int
    var accuracy: MagneticFieldAccuracy
    var source: MagneticFieldSource
    /// Difference between the sample timestamp and the matched camera pose, seconds.
    var timingError: TimeInterval
    var trackingQuality: TrackingQuality
    var raycastQuality: RaycastQuality
    /// Position on the locked wall, metres.
    var wallPoint: WallPoint
    /// Position in world space, metres.
    var worldPosition: Vector3
    /// Distance from the camera to the wall at the moment of the reading, metres.
    var wallDistance: Double
    /// Camera speed at the moment of the reading, m/s.
    var cameraSpeed: Double
    /// Which pass produced it.
    var passIndex: Int
    /// The cluster this measurement was merged into.
    var clusterID: UUID
}

/// Aggregate quality information for a whole scan.
struct ScanQualitySummary: Codable, Sendable, Hashable {
    /// Candidates the detector produced.
    var candidatesProduced: Int
    /// Candidates that passed every gate and were mapped onto the wall.
    var candidatesAccepted: Int
    /// Histogram of blocking reasons, keyed by `QualityReason.rawValue`.
    var rejectionCounts: [String: Int]
    /// Mean sensor-to-pose timing error among accepted measurements, seconds.
    var meanTimingError: TimeInterval
    /// Worst timing error among accepted measurements, seconds.
    var worstTimingError: TimeInterval
    /// Mean camera speed among accepted measurements, m/s.
    var meanCameraSpeed: Double
    /// Fraction of the scan during which tracking was normal, `0...1`.
    var trackingNormalFraction: Double
    /// Measured sensor delivery rate over the scan, Hz.
    var measuredSampleRate: Double
    /// Number of distinct passes.
    var passCount: Int

    var acceptanceRate: Double {
        candidatesProduced > 0 ? Double(candidatesAccepted) / Double(candidatesProduced) : 0
    }

    /// Rejection reasons ordered by how often they occurred.
    var rankedRejections: [(reason: QualityReason, count: Int)] {
        rejectionCounts
            .compactMap { key, value in
                QualityReason(rawValue: key).map { ($0, value) }
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.rawValue < rhs.0.rawValue : lhs.1 > rhs.1
            }
    }

    static let empty = ScanQualitySummary(
        candidatesProduced: 0,
        candidatesAccepted: 0,
        rejectionCounts: [:],
        meanTimingError: 0,
        worstTimingError: 0,
        meanCameraSpeed: 0,
        trackingNormalFraction: 0,
        measuredSampleRate: 0,
        passCount: 0
    )
}

/// A saved scan.
///
/// # Versioning
///
/// `schemaVersion` is written on every record. `ScanRecord.currentSchemaVersion`
/// is the newest the running build understands. A record with a *higher* version
/// is not decoded and not silently downgraded -- it is surfaced to the user as
/// "made by a newer version of the app" so no data is destroyed. A record with a
/// lower version is migrated by `ScanRecord.migrated(from:)`.
///
/// # What is deliberately not stored
///
/// No location, no persistent device identifier, no advertising identifier, no
/// account, no photographs and no camera frames. The stored device metadata
/// identifies a *hardware model*, which is required to compare sensor behaviour
/// across iPhone models during validation.
struct ScanRecord: Codable, Sendable, Hashable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var duration: TimeInterval

    var appVersion: String
    var algorithmVersion: String
    var device: DeviceMetadata
    /// Whether this scan was produced from simulated data. Simulated scans are
    /// labelled everywhere they appear and can never be mistaken for a
    /// measurement.
    var isSimulated: Bool

    var detectorConfiguration: DetectorConfiguration
    var sensitivity: SensitivityPreset
    var calibration: CalibrationSummary
    var wall: WallMetadata

    var measurements: [StoredMeasurement]
    var clusters: [AnomalyCluster]
    var quality: ScanQualitySummary

    /// Free-text tags the user can attach during validation work, e.g.
    /// "control region", "known screw at 40 cm".
    var validationTags: [String]

    var clusterCount: Int { clusters.count }
    var repeatedClusterCount: Int { clusters.lazy.filter { $0.confidence == .repeated }.count }
    var unconfirmedClusterCount: Int { clusters.lazy.filter { $0.confidence == .unconfirmed }.count }

    /// True when the scan produced no clusters at all. The UI must render this
    /// as `SafetyCopy.noAnomalyHeadline` plus `noAnomalySubtitle`, never as a
    /// success or "clear" state.
    var hasNoAnomalies: Bool { clusters.isEmpty }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Scan \(Format.scanDate.string(from: createdAt))"
            : name
    }

    /// Bounds used for the 2D summary map.
    var summaryBounds: WallBounds {
        if let bounds = WallBounds.containing(clusters.map(\.wallPoint), padding: 0.12) {
            return bounds
        }
        return wall.displayBounds
    }

    init(
        schemaVersion: Int = ScanRecord.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        createdAt: Date,
        updatedAt: Date,
        duration: TimeInterval,
        appVersion: String,
        algorithmVersion: String,
        device: DeviceMetadata,
        isSimulated: Bool,
        detectorConfiguration: DetectorConfiguration,
        sensitivity: SensitivityPreset,
        calibration: CalibrationSummary,
        wall: WallMetadata,
        measurements: [StoredMeasurement],
        clusters: [AnomalyCluster],
        quality: ScanQualitySummary,
        validationTags: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.appVersion = appVersion
        self.algorithmVersion = algorithmVersion
        self.device = device
        self.isSimulated = isSimulated
        self.detectorConfiguration = detectorConfiguration
        self.sensitivity = sensitivity
        self.calibration = calibration
        self.wall = wall
        self.measurements = measurements
        self.clusters = clusters
        self.quality = quality
        self.validationTags = validationTags
    }

    /// Applies any migrations needed to bring an older record up to the current
    /// schema. Version 1 is the first shipping schema, so there is nothing to
    /// migrate yet; the hook exists so the first real migration has an obvious
    /// home and a test to extend.
    func migrated() -> ScanRecord {
        var record = self
        if record.schemaVersion < ScanRecord.currentSchemaVersion {
            record.schemaVersion = ScanRecord.currentSchemaVersion
        }
        record.detectorConfiguration = record.detectorConfiguration.sanitized()
        return record
    }
}

/// A lightweight row for the history list, so opening the list never decodes
/// every measurement of every scan.
struct ScanSummary: Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var duration: TimeInterval
    var clusterCount: Int
    var repeatedClusterCount: Int
    var isSimulated: Bool
    var algorithmVersion: String

    init(record: ScanRecord) {
        self.id = record.id
        self.name = record.displayName
        self.createdAt = record.createdAt
        self.duration = record.duration
        self.clusterCount = record.clusterCount
        self.repeatedClusterCount = record.repeatedClusterCount
        self.isSimulated = record.isSimulated
        self.algorithmVersion = record.algorithmVersion
    }

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        duration: TimeInterval,
        clusterCount: Int,
        repeatedClusterCount: Int,
        isSimulated: Bool,
        algorithmVersion: String
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.duration = duration
        self.clusterCount = clusterCount
        self.repeatedClusterCount = repeatedClusterCount
        self.isSimulated = isSimulated
        self.algorithmVersion = algorithmVersion
    }
}

import Foundation
import simd
@testable import WallField

/// Builders for deterministic synthetic data.
///
/// Every unit test drives the pipeline with data built here rather than with a
/// recording, so a failure always points at the code rather than at a fixture
/// that drifted.
enum Fixture {

    static let baseTimestamp: TimeInterval = 10_000

    /// A field vector whose magnitude is exactly `magnitude`.
    static func vector(magnitude: Double) -> SIMD3<Double> {
        let direction = SIMD3<Double>(0.3, 0.5, 0.8)
        let length = (direction.x * direction.x
            + direction.y * direction.y
            + direction.z * direction.z).squareRoot()
        return (direction / length) * magnitude
    }

    static func sample(
        magnitude: Double,
        at timestamp: TimeInterval,
        interval: TimeInterval = 0.02,
        accuracy: MagneticFieldAccuracy = .high,
        source: MagneticFieldSource = .simulated,
        motion: MotionEnergy? = MotionEnergy.still
    ) -> MagneticFieldSample {
        let v = vector(magnitude: magnitude)
        return MagneticFieldSample(
            timestamp: timestamp,
            x: v.x, y: v.y, z: v.z,
            accuracy: accuracy,
            interval: interval,
            source: source,
            motion: motion
        )
    }

    /// A run of samples whose magnitude is supplied per index.
    static func stream(
        count: Int,
        interval: TimeInterval = 0.02,
        start: TimeInterval = baseTimestamp,
        accuracy: MagneticFieldAccuracy = .high,
        source: MagneticFieldSource = .simulated,
        motion: MotionEnergy? = MotionEnergy.still,
        magnitude: (Int) -> Double
    ) -> [MagneticFieldSample] {
        (0..<count).map { index in
            sample(
                magnitude: magnitude(index),
                at: start + Double(index) * interval,
                interval: index == 0 ? 0 : interval,
                accuracy: accuracy,
                source: source,
                motion: motion
            )
        }
    }

    /// Reproducible zero-mean noise. A fixed seed means a test that passes once
    /// passes every time.
    static func noise(seed: UInt64 = 42, sigma: Double, count: Int) -> [Double] {
        var random = DeterministicRandom(seed: seed)
        return (0..<count).map { _ in random.gaussian() * sigma }
    }

    static func calibration(
        baseline: Double = 48,
        sigma: Double = 0.2,
        source: MagneticFieldSource = .simulated
    ) -> CalibrationSummary {
        CalibrationSummary(
            baselineMagnitude: baseline,
            sigma: sigma,
            medianAbsoluteDeviation: sigma / RobustStatistics.madToSigma,
            rawMedianAbsoluteDeviation: sigma / RobustStatistics.madToSigma,
            sigmaWasFloored: false,
            range: sigma * 6,
            meanVector: Vector3(x: 0, y: 0, z: Float(baseline)),
            sampleCount: 150,
            duration: 3,
            worstAccuracy: .high,
            measuredSampleRate: 50,
            source: source,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Spatial

    /// A wall frame in a world where the wall is the XY plane at the origin and
    /// its normal points along +Z.
    static var wallFrame: WallFrame { WallFrame(
        origin: Vector3(x: 0, y: 0, z: 0),
        right: Vector3(x: 1, y: 0, z: 0),
        up: Vector3(x: 0, y: 1, z: 0),
        normal: Vector3(x: 0, y: 0, z: 1)
    ) }

    /// The matching plane-anchor transform: local +Y is the plane normal.
    ///
    /// Computed rather than stored so the fixture makes no `Sendable` claim
    /// about the simd matrix type.
    static var anchorTransform: simd_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(1, 0, 0, 0)
        transform.columns.1 = SIMD4<Float>(0, 0, 1, 0)
        transform.columns.2 = SIMD4<Float>(0, -1, 0, 0)
        transform.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        return transform
    }

    static func hit(
        at wallPoint: WallPoint,
        distance: Double = 0.1,
        quality: RaycastQuality = .planeGeometry,
        extrapolation: Double = 0
    ) -> WallHit {
        let world = wallFrame.worldPosition(forWallPoint: wallPoint)
        return WallHit(
            worldPosition: world,
            anchorLocalPosition: SIMD3<Float>(Float(wallPoint.x), 0, Float(-wallPoint.y)),
            wallPoint: wallPoint,
            distanceFromCamera: distance,
            quality: quality,
            extrapolationDistance: extrapolation
        )
    }

    static func spatialSample(
        at timestamp: TimeInterval,
        wallPoint: WallPoint? = WallPoint(x: 0, y: 0),
        tracking: TrackingQuality = .normal,
        speed: Double = 0.1,
        distance: Double = 0.1,
        quality: RaycastQuality = .planeGeometry
    ) -> SpatialSample {
        SpatialSample(
            timestamp: timestamp,
            cameraTransform: matrix_identity_float4x4,
            wallTransform: anchorTransform,
            hit: wallPoint.map { hit(at: $0, distance: distance, quality: quality) },
            tracking: tracking,
            cameraSpeed: speed
        )
    }

    static func match(
        at timestamp: TimeInterval,
        wallPoint: WallPoint = WallPoint(x: 0, y: 0),
        timingError: TimeInterval = 0.005,
        tracking: TrackingQuality = .normal,
        speed: Double = 0.1,
        distance: Double = 0.1,
        quality: RaycastQuality = .planeGeometry
    ) -> SpatialMatch {
        SpatialMatch(
            sample: spatialSample(
                at: timestamp, wallPoint: wallPoint, tracking: tracking,
                speed: speed, distance: distance, quality: quality
            ),
            timingError: timingError
        )
    }

    static var healthyTiming: SampleTimingHealth {
        SampleTimingHealth(measuredRate: 50, meanInterval: 0.02, maximumGap: 0.02, sampleCount: 100)
    }

    static var availableSensor: MagneticFieldAvailability { MagneticFieldAvailability(
        isDeviceMotionAvailable: true,
        isMagnetometerAvailable: true,
        isAttitudeReferenceFrameAvailable: true,
        activeSource: .simulated,
        failureDescription: nil
    ) }

    // MARK: - Records

    static func candidate(
        delta: Double = 8,
        z: Double = 12,
        persistence: Int = 4,
        at timestamp: TimeInterval = baseTimestamp
    ) -> AnomalyCandidate {
        AnomalyCandidate(
            id: UUID(),
            timestamp: timestamp,
            sample: sample(magnitude: 48 + delta, at: timestamp),
            smoothedMagnitude: 48 + delta,
            baseline: 48,
            delta: delta,
            robustZScore: z,
            gradient: 4,
            persistence: persistence,
            sigma: 0.2
        )
    }

    static func scanRecord(
        clusters: [AnomalyCluster] = [],
        measurements: [StoredMeasurement] = [],
        name: String = "Test scan",
        isSimulated: Bool = true
    ) -> ScanRecord {
        ScanRecord(
            id: UUID(),
            name: name,
            notes: "Recorded against a control wall.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            duration: 123,
            appVersion: "1.0.0 (1)",
            algorithmVersion: AlgorithmVersion.current,
            device: DeviceMetadata(
                model: "iPhone16,1",
                systemName: "iOS",
                systemVersion: "Version 18.0",
                supportsSceneDepth: false,
                supportsSceneReconstruction: false
            ),
            isSimulated: isSimulated,
            detectorConfiguration: .default,
            sensitivity: .medium,
            calibration: calibration(),
            wall: WallMetadata(
                anchorIdentifier: UUID(),
                frame: wallFrame,
                extentWidth: 1.4,
                extentHeight: 1.6,
                coveredBounds: nil
            ),
            measurements: measurements,
            clusters: clusters,
            quality: ScanQualitySummary(
                candidatesProduced: 20,
                candidatesAccepted: 14,
                rejectionCounts: [QualityReason.movingTooFast.rawValue: 4,
                                  QualityReason.timingMismatch.rawValue: 2],
                meanTimingError: 0.012,
                worstTimingError: 0.041,
                meanCameraSpeed: 0.14,
                trackingNormalFraction: 0.97,
                measuredSampleRate: 49.4,
                passCount: 2
            ),
            validationTags: ["control region"]
        )
    }

    static func cluster(
        at wallPoint: WallPoint = WallPoint(x: 0.1, y: 0.2),
        passes: [Int] = [0],
        peakDelta: Double = 9.5
    ) -> AnomalyCluster {
        AnomalyCluster(
            id: UUID(),
            wallPoint: wallPoint,
            anchorLocalPosition: Vector3(x: Float(wallPoint.x), y: 0, z: Float(-wallPoint.y)),
            worldPosition: Vector3(wallFrame.worldPosition(forWallPoint: wallPoint)),
            peakDelta: peakDelta,
            peakZScore: 14,
            peakScore: 0.72,
            totalWeight: 2.1,
            sampleCount: 3,
            passIndices: passes,
            firstSeen: Date(timeIntervalSince1970: 1_700_000_010),
            lastSeen: Date(timeIntervalSince1970: 1_700_000_020),
            lastSeenMonotonic: baseTimestamp + 20,
            bestRaycastQuality: .planeGeometry,
            worstTimingError: 0.018,
            polarity: peakDelta >= 0 ? .positive : .negative
        )
    }
}

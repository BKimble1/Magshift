import Foundation

/// Everything the gate needs to judge one candidate.
///
/// Main-actor only, like the pose buffer it draws on, so it makes no `Sendable`
/// claim.
struct ScanQualityInputs {
    var availability: MagneticFieldAvailability
    var timing: SampleTimingHealth
    var isCalibrated: Bool
    var isWallLocked: Bool
    var candidate: AnomalyCandidate
    var match: SpatialMatch?
    var clusterCount: Int
}

/// The single place that decides whether a candidate may be placed on the wall.
///
/// Every condition in the product requirements is checked here, in one pure
/// function, so the rules can be read in one screen and tested exhaustively.
/// Nothing else in the app is allowed to place a marker.
struct ScanQualityGate {
    let configuration: DetectorConfiguration

    init(configuration: DetectorConfiguration) {
        self.configuration = configuration.sanitized()
    }

    func evaluate(_ inputs: ScanQualityInputs) -> ScanQualityVerdict {
        var blocking: [QualityReason] = []
        var advisory: [QualityReason] = []

        // 1. The sensor must be delivering usable data.
        if inputs.availability.isUnavailable {
            blocking.append(.magnetometerUnavailable)
        }
        if !inputs.candidate.sample.source.isAcceptableForDetection {
            blocking.append(.reducedQualitySource)
        }

        // 2. Sample timing must be healthy.
        if !inputs.timing.isHealthy {
            blocking.append(.sampleTimingUnstable)
        }

        // 3. Calibration accuracy must be acceptable.
        if !inputs.candidate.sample.accuracy.isAcceptable {
            blocking.append(.calibrationAccuracyLow)
        }

        // 4. A baseline must exist.
        if !inputs.isCalibrated {
            blocking.append(.baselineNotEstablished)
        }

        // 5. A wall must be locked.
        if !inputs.isWallLocked {
            blocking.append(.wallNotLocked)
        }

        // 6. Detector evidence must be persistent, not a single sample.
        if inputs.candidate.persistence < configuration.persistenceRequired {
            blocking.append(.insufficientPersistence)
        }

        // 7. There must be a close enough pose, and it must hit the locked wall.
        guard let match = inputs.match else {
            blocking.append(.timingMismatch)
            return finish(blocking: blocking, advisory: advisory, inputs: inputs)
        }
        if match.timingError > configuration.timestampTolerance {
            blocking.append(.timingMismatch)
        }
        if !match.sample.tracking.permitsPlacement {
            blocking.append(.trackingNotNormal)
        }
        if match.sample.cameraSpeed > configuration.maximumScanSpeed {
            blocking.append(.movingTooFast)
        }

        guard let hit = match.sample.hit, hit.quality.permitsPlacement else {
            blocking.append(.noWallIntersection)
            return finish(blocking: blocking, advisory: advisory, inputs: inputs)
        }
        if hit.quality == .extrapolatedPlane {
            if hit.extrapolationDistance > configuration.maximumExtrapolationDistance {
                blocking.append(.noWallIntersection)
            } else {
                advisory.append(.extrapolatedIntersection)
            }
        }
        if hit.distanceFromCamera < configuration.minimumWallDistance {
            blocking.append(.tooCloseToWall)
        }
        if hit.distanceFromCamera > configuration.maximumWallDistance {
            blocking.append(.tooFarFromWall)
        }

        return finish(blocking: blocking, advisory: advisory, inputs: inputs)
    }

    private func finish(
        blocking: [QualityReason],
        advisory: [QualityReason],
        inputs: ScanQualityInputs
    ) -> ScanQualityVerdict {
        var blocking = blocking
        // 8. Bounded output: never exceed the rendered-cluster limit.
        if inputs.clusterCount >= configuration.maximumClusters {
            blocking.append(.clusterLimitReached)
        }
        return ScanQualityVerdict(blocking: blocking, advisory: advisory)
    }

    /// Live gate used for the HUD when there is no candidate: reports what would
    /// currently stop a reading being placed, so the user can fix it *before*
    /// passing over something interesting.
    func liveObstruction(
        availability: MagneticFieldAvailability,
        timing: SampleTimingHealth,
        isCalibrated: Bool,
        isWallLocked: Bool,
        accuracy: MagneticFieldAccuracy,
        newest: SpatialSample?
    ) -> QualityReason? {
        if availability.isUnavailable { return .magnetometerUnavailable }
        if !timing.isHealthy { return .sampleTimingUnstable }
        if !accuracy.isAcceptable { return .calibrationAccuracyLow }
        if !isCalibrated { return .baselineNotEstablished }
        if !isWallLocked { return .wallNotLocked }
        guard let newest else { return .trackingNotNormal }
        if !newest.tracking.permitsPlacement { return .trackingNotNormal }
        if newest.cameraSpeed > configuration.maximumScanSpeed { return .movingTooFast }
        guard let hit = newest.hit, hit.quality.permitsPlacement else { return .noWallIntersection }
        if hit.distanceFromCamera < configuration.minimumWallDistance { return .tooCloseToWall }
        if hit.distanceFromCamera > configuration.maximumWallDistance { return .tooFarFromWall }
        return nil
    }
}

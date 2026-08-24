import XCTest
@testable import WallField

final class ScanQualityGateTests: XCTestCase {

    private let gate = ScanQualityGate(configuration: .default)
    private let config = DetectorConfiguration.default

    private func inputs(
        availability: MagneticFieldAvailability = Fixture.availableSensor,
        timing: SampleTimingHealth = Fixture.healthyTiming,
        isCalibrated: Bool = true,
        isWallLocked: Bool = true,
        candidate: AnomalyCandidate? = nil,
        match: SpatialMatch? = nil,
        // Separate from `match` on purpose. `match: nil` means "use the default
        // one", so without this there is no way to express the case that matters
        // most -- no pose close enough in time to anchor the reading at all.
        hasPose: Bool = true,
        clusterCount: Int = 0
    ) -> ScanQualityInputs {
        ScanQualityInputs(
            availability: availability,
            timing: timing,
            isCalibrated: isCalibrated,
            isWallLocked: isWallLocked,
            candidate: candidate ?? Fixture.candidate(),
            match: hasPose ? (match ?? Fixture.match(at: Fixture.baseTimestamp)) : nil,
            clusterCount: clusterCount
        )
    }

    func testAcceptsAGoodReading() {
        let verdict = gate.evaluate(inputs())
        XCTAssertTrue(verdict.accepts, "blocked by \(verdict.blocking)")
        XCTAssertTrue(verdict.advisory.isEmpty)
    }

    func testRejectsWhenTheSensorIsUnavailable() {
        let verdict = gate.evaluate(inputs(availability: .unavailable))
        XCTAssertFalse(verdict.accepts)
        XCTAssertTrue(verdict.blocking.contains(.magnetometerUnavailable))
        XCTAssertEqual(verdict.primaryReason, .magnetometerUnavailable)
    }

    func testRejectsRawMagnetometerData() {
        // Raw data has no bias removal and no accuracy estimate, so it can never
        // anchor a marker however large the reading is.
        var candidate = Fixture.candidate()
        candidate.sample = Fixture.sample(
            magnitude: 90, at: Fixture.baseTimestamp, accuracy: .high, source: .rawMagnetometer
        )
        let verdict = gate.evaluate(inputs(candidate: candidate))
        XCTAssertFalse(verdict.accepts)
        XCTAssertTrue(verdict.blocking.contains(.reducedQualitySource))
    }

    func testRejectsUnhealthyTiming() {
        let stalled = SampleTimingHealth(
            measuredRate: 6, meanInterval: 0.17, maximumGap: 0.9, sampleCount: 40
        )
        let verdict = gate.evaluate(inputs(timing: stalled))
        XCTAssertTrue(verdict.blocking.contains(.sampleTimingUnstable))
    }

    func testRejectsLowCalibrationAccuracy() {
        var candidate = Fixture.candidate()
        candidate.sample = Fixture.sample(magnitude: 56, at: Fixture.baseTimestamp, accuracy: .low)
        XCTAssertTrue(gate.evaluate(inputs(candidate: candidate)).blocking.contains(.calibrationAccuracyLow))
    }

    func testRejectsWithoutABaseline() {
        XCTAssertTrue(gate.evaluate(inputs(isCalibrated: false)).blocking.contains(.baselineNotEstablished))
    }

    func testRejectsWithoutALockedWall() {
        XCTAssertTrue(gate.evaluate(inputs(isWallLocked: false)).blocking.contains(.wallNotLocked))
    }

    func testRejectsInsufficientPersistence() {
        let candidate = Fixture.candidate(persistence: 1)
        XCTAssertTrue(gate.evaluate(inputs(candidate: candidate)).blocking.contains(.insufficientPersistence))
    }

    func testRejectsWhenNoPoseIsCloseEnoughInTime() {
        let verdict = gate.evaluate(inputs(hasPose: false))
        XCTAssertFalse(verdict.accepts)
        XCTAssertTrue(verdict.blocking.contains(.timingMismatch))
    }

    func testRejectsWhenTheMatchedPoseIsTooOld() {
        let stale = Fixture.match(at: Fixture.baseTimestamp, timingError: 0.4)
        XCTAssertTrue(gate.evaluate(inputs(match: stale)).blocking.contains(.timingMismatch))
    }

    func testRejectsLimitedTracking() {
        let limited = Fixture.match(at: Fixture.baseTimestamp, tracking: .limited(.insufficientFeatures))
        XCTAssertTrue(gate.evaluate(inputs(match: limited)).blocking.contains(.trackingNotNormal))
    }

    func testRejectsExcessiveScanSpeed() {
        let fast = Fixture.match(at: Fixture.baseTimestamp, speed: config.maximumScanSpeed + 0.2)
        XCTAssertTrue(gate.evaluate(inputs(match: fast)).blocking.contains(.movingTooFast))
    }

    func testAcceptsAtTheSpeedLimit() {
        let atLimit = Fixture.match(at: Fixture.baseTimestamp, speed: config.maximumScanSpeed)
        XCTAssertTrue(gate.evaluate(inputs(match: atLimit)).accepts)
    }

    func testRejectsWhenTheCrosshairMissesTheWall() {
        let missed = SpatialMatch(
            sample: Fixture.spatialSample(at: Fixture.baseTimestamp, wallPoint: nil),
            timingError: 0.004
        )
        XCTAssertTrue(gate.evaluate(inputs(match: missed)).blocking.contains(.noWallIntersection))
    }

    func testRejectsDistancesOutsideTheWorkingRange() {
        let tooClose = Fixture.match(at: Fixture.baseTimestamp, distance: 0.001)
        XCTAssertTrue(gate.evaluate(inputs(match: tooClose)).blocking.contains(.tooCloseToWall))
        let tooFar = Fixture.match(at: Fixture.baseTimestamp, distance: 2.0)
        XCTAssertTrue(gate.evaluate(inputs(match: tooFar)).blocking.contains(.tooFarFromWall))
    }

    func testExtrapolatedHitIsAdvisoryNotBlocking() {
        // A hit just past the mapped edge is accepted, but the reduced spatial
        // quality is recorded and travels with the measurement.
        let sample = SpatialSample(
            timestamp: Fixture.baseTimestamp,
            cameraTransform: Fixture.anchorTransform,
            wallTransform: Fixture.anchorTransform,
            hit: Fixture.hit(at: WallPoint(x: 0.1, y: 0), quality: .extrapolatedPlane, extrapolation: 0.05),
            tracking: .normal,
            cameraSpeed: 0.1
        )
        let verdict = gate.evaluate(inputs(match: SpatialMatch(sample: sample, timingError: 0.004)))
        XCTAssertTrue(verdict.accepts)
        XCTAssertTrue(verdict.advisory.contains(.extrapolatedIntersection))
    }

    func testExtrapolationBeyondTheLimitIsRejected() {
        let sample = SpatialSample(
            timestamp: Fixture.baseTimestamp,
            cameraTransform: Fixture.anchorTransform,
            wallTransform: Fixture.anchorTransform,
            hit: Fixture.hit(at: WallPoint(x: 0.1, y: 0), quality: .extrapolatedPlane, extrapolation: 0.5),
            tracking: .normal,
            cameraSpeed: 0.1
        )
        let verdict = gate.evaluate(inputs(match: SpatialMatch(sample: sample, timingError: 0.004)))
        XCTAssertFalse(verdict.accepts)
        XCTAssertTrue(verdict.blocking.contains(.noWallIntersection))
    }

    func testRejectsOnceTheClusterLimitIsReached() {
        let verdict = gate.evaluate(inputs(clusterCount: config.maximumClusters))
        XCTAssertTrue(verdict.blocking.contains(.clusterLimitReached))
    }

    func testPrimaryReasonReportsTheMostFundamentalProblem() {
        // When several things are wrong at once the user is told the one that
        // has to be fixed first.
        let verdict = gate.evaluate(inputs(
            availability: .unavailable,
            isCalibrated: false,
            isWallLocked: false,
            match: nil
        ))
        XCTAssertEqual(verdict.primaryReason, .magnetometerUnavailable)
    }

    func testEveryReasonHasGuidanceAndAnExplanation() {
        for reason in QualityReason.allCases {
            XCTAssertFalse(reason.guidance.isEmpty, "\(reason) has no guidance")
            XCTAssertFalse(reason.explanation.isEmpty, "\(reason) has no explanation")
        }
    }

    // MARK: - Live obstruction

    func testLiveObstructionIsNilWhenEverythingIsReady() {
        XCTAssertNil(gate.liveObstruction(
            availability: Fixture.availableSensor,
            timing: Fixture.healthyTiming,
            isCalibrated: true,
            isWallLocked: true,
            accuracy: .high,
            newest: Fixture.spatialSample(at: 0)
        ))
    }

    func testLiveObstructionNamesTheMissingWall() {
        XCTAssertEqual(
            gate.liveObstruction(
                availability: Fixture.availableSensor,
                timing: Fixture.healthyTiming,
                isCalibrated: true,
                isWallLocked: true,
                accuracy: .high,
                newest: Fixture.spatialSample(at: 0, wallPoint: nil)
            ),
            .noWallIntersection
        )
    }

    func testLiveObstructionWithoutAnyPose() {
        XCTAssertEqual(
            gate.liveObstruction(
                availability: Fixture.availableSensor,
                timing: Fixture.healthyTiming,
                isCalibrated: true,
                isWallLocked: true,
                accuracy: .high,
                newest: nil
            ),
            .trackingNotNormal
        )
    }
}

import XCTest
@testable import WallField

final class ClusterEngineTests: XCTestCase {

    private let config = DetectorConfiguration.default

    private func engine() -> ClusterEngine {
        ClusterEngine(configuration: config)
    }

    @discardableResult
    private func add(
        _ engine: inout ClusterEngine,
        at wallPoint: WallPoint,
        delta: Double = 9,
        z: Double = 15,
        timestamp: TimeInterval = Fixture.baseTimestamp,
        passIndex: Int = 0,
        quality: RaycastQuality = .planeGeometry,
        timingError: TimeInterval = 0.005
    ) -> ClusterEngine.Outcome {
        engine.add(
            candidate: Fixture.candidate(delta: delta, z: z, at: timestamp),
            match: Fixture.match(
                at: timestamp, wallPoint: wallPoint,
                timingError: timingError, quality: quality
            ),
            passIndex: passIndex,
            scanStart: Fixture.baseTimestamp,
            date: Date(timeIntervalSince1970: 1_700_000_000 + timestamp)
        )
    }

    // MARK: - Merging

    func testFirstCandidateCreatesACluster() {
        var engine = engine()
        let outcome = add(&engine, at: WallPoint(x: 0, y: 0))
        XCTAssertTrue(outcome.isNewCluster)
        XCTAssertEqual(engine.clusters.count, 1)
        XCTAssertEqual(engine.measurements.count, 1)
    }

    func testNearbyCandidatesMergeIntoOneCluster() {
        // One physical region must produce one marker, not one per sample.
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0))
        for index in 1...20 {
            add(&engine, at: WallPoint(x: 0.005 * Double(index % 4), y: 0.005),
                timestamp: Fixture.baseTimestamp + Double(index) * 0.4)
        }
        XCTAssertEqual(engine.clusters.count, 1)
        XCTAssertEqual(engine.clusters[0].sampleCount, 21)
        XCTAssertEqual(engine.measurements.count, 21)
    }

    func testCandidatesBeyondTheRadiusMakeSeparateClusters() {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0))
        add(&engine, at: WallPoint(x: config.clusterRadius * 2, y: 0))
        XCTAssertEqual(engine.clusters.count, 2)
    }

    func testHitsJustInsideTheRadiusMergeAndJustOutsideDoNot() {
        var inside = engine()
        add(&inside, at: WallPoint(x: 0, y: 0))
        add(&inside, at: WallPoint(x: config.clusterRadius * 0.99, y: 0))
        XCTAssertEqual(inside.clusters.count, 1, "a hit inside the radius should merge")

        var outside = engine()
        add(&outside, at: WallPoint(x: 0, y: 0))
        add(&outside, at: WallPoint(x: config.clusterRadius * 1.01, y: 0))
        XCTAssertEqual(outside.clusters.count, 2, "a hit outside the radius should not merge")
    }

    func testCentroidIsWeightedByScore() {
        var engine = engine()
        // A weak reading at the origin, then a much stronger one 3 cm away: the
        // centroid should sit closer to the stronger reading.
        add(&engine, at: WallPoint(x: 0, y: 0), delta: 4.2, z: 5.2)
        add(&engine, at: WallPoint(x: 0.03, y: 0), delta: 40, z: 80,
            timestamp: Fixture.baseTimestamp + 0.5)
        let centroid = engine.clusters[0].wallPoint
        XCTAssertGreaterThan(centroid.x, 0.015)
        XCTAssertLessThan(centroid.x, 0.03)
    }

    func testPeakStatisticsTrackTheStrongestContributor() {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0), delta: 6, z: 8)
        add(&engine, at: WallPoint(x: 0.01, y: 0), delta: 22, z: 40,
            timestamp: Fixture.baseTimestamp + 0.5)
        add(&engine, at: WallPoint(x: 0.01, y: 0), delta: 7, z: 9,
            timestamp: Fixture.baseTimestamp + 1.0)
        let cluster = engine.clusters[0]
        XCTAssertEqual(cluster.peakDelta, 22, accuracy: 1e-9)
        XCTAssertEqual(cluster.peakZScore, 40, accuracy: 1e-9)
        XCTAssertEqual(cluster.sampleCount, 3)
    }

    func testLargestMagnitudeWinsRegardlessOfSign() {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0), delta: 6)
        add(&engine, at: WallPoint(x: 0.01, y: 0), delta: -18,
            timestamp: Fixture.baseTimestamp + 0.5)
        XCTAssertEqual(engine.clusters[0].peakDelta, -18, accuracy: 1e-9)
        XCTAssertEqual(engine.clusters[0].polarity, .negative)
    }

    func testBestSpatialQualityAndWorstTimingErrorAreKept() {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0), quality: .extrapolatedPlane, timingError: 0.01)
        add(&engine, at: WallPoint(x: 0.01, y: 0), timestamp: Fixture.baseTimestamp + 0.5,
            quality: .planeGeometry, timingError: 0.06)
        XCTAssertEqual(engine.clusters[0].bestRaycastQuality, .planeGeometry)
        XCTAssertEqual(engine.clusters[0].worstTimingError, 0.06, accuracy: 1e-9)
    }

    // MARK: - Confidence

    func testASinglePassStaysUnconfirmedHoweverLargeTheReading() {
        var engine = engine()
        for index in 0..<40 {
            add(&engine, at: WallPoint(x: 0, y: 0), delta: 120, z: 400,
                timestamp: Fixture.baseTimestamp + Double(index) * 0.4)
        }
        XCTAssertEqual(engine.clusters[0].confidence, .unconfirmed)
        XCTAssertEqual(engine.clusters[0].passCount, 1)
    }

    func testASecondPassOverTheSamePlaceRaisesConfidence() {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0), timestamp: Fixture.baseTimestamp)
        add(&engine, at: WallPoint(x: 0.01, y: 0),
            timestamp: Fixture.baseTimestamp + 30, passIndex: 1)
        XCTAssertEqual(engine.clusters[0].confidence, .repeated)
        XCTAssertEqual(engine.clusters[0].passCount, 2)
    }

    func testANewPassTooSoonDoesNotCountAsRepeatedEvidence() {
        // Tapping "new pass" mid-sweep must not promote a reading without new
        // evidence, so a later pass only counts after a real interval.
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0), timestamp: Fixture.baseTimestamp)
        add(&engine, at: WallPoint(x: 0.005, y: 0),
            timestamp: Fixture.baseTimestamp + 0.2, passIndex: 1)
        XCTAssertEqual(engine.clusters[0].confidence, .unconfirmed)
        XCTAssertEqual(engine.clusters[0].passCount, 1)
    }

    func testASecondPassSomewhereElseDoesNotConfirmTheFirst() {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0))
        add(&engine, at: WallPoint(x: 0.5, y: 0),
            timestamp: Fixture.baseTimestamp + 30, passIndex: 1)
        XCTAssertEqual(engine.clusters.count, 2)
        XCTAssertTrue(engine.clusters.allSatisfy { $0.confidence == .unconfirmed })
    }

    // MARK: - Bounds

    func testClusterCountIsBounded() {
        var engine = engine()
        for index in 0..<(config.maximumClusters + 25) {
            add(&engine, at: WallPoint(x: Double(index) * 0.5, y: 0),
                timestamp: Fixture.baseTimestamp + Double(index) * 0.4)
        }
        XCTAssertEqual(engine.clusters.count, config.maximumClusters)
    }

    func testExcessCandidatesAreRejectedWithAReason() {
        var engine = engine()
        for index in 0..<config.maximumClusters {
            add(&engine, at: WallPoint(x: Double(index) * 0.5, y: 0),
                timestamp: Fixture.baseTimestamp + Double(index) * 0.4)
        }
        let outcome = add(&engine, at: WallPoint(x: 9999, y: 0))
        XCTAssertEqual(outcome, .rejected(.clusterLimitReached))
    }

    func testMeasurementStorageIsBoundedAndReportsWhatWasDropped() {
        var config = DetectorConfiguration.default
        config.maximumMeasurements = 10
        var engine = ClusterEngine(configuration: config)
        for index in 0..<25 {
            _ = engine.add(
                candidate: Fixture.candidate(at: Fixture.baseTimestamp + Double(index) * 0.4),
                match: Fixture.match(at: Fixture.baseTimestamp + Double(index) * 0.4,
                                     wallPoint: WallPoint(x: 0, y: 0)),
                passIndex: 0,
                scanStart: Fixture.baseTimestamp,
                date: Date()
            )
        }
        XCTAssertEqual(engine.measurements.count, 10)
        XCTAssertEqual(engine.droppedMeasurementCount, 15)
    }

    // MARK: - Editing

    func testUndoRemovesTheNewestClusterAndItsMeasurements() throws {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0))
        add(&engine, at: WallPoint(x: 0.5, y: 0), timestamp: Fixture.baseTimestamp + 1)
        let removed = try XCTUnwrap(engine.undoLastCluster())
        XCTAssertEqual(engine.clusters.count, 1)
        XCTAssertFalse(engine.measurements.contains { $0.clusterID == removed.id })
        XCTAssertEqual(engine.measurements.count, 1)
    }

    func testUndoOnAnEmptyEngineIsHarmless() {
        var engine = engine()
        XCTAssertNil(engine.undoLastCluster())
    }

    func testRemoveAllClears() {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0))
        engine.removeAll()
        XCTAssertTrue(engine.clusters.isEmpty)
        XCTAssertTrue(engine.measurements.isEmpty)
        XCTAssertEqual(engine.droppedMeasurementCount, 0)
    }

    // MARK: - Haptics

    func testHapticsAreThrottledPerCluster() {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0))
        let id = engine.clusters[0].id
        XCTAssertTrue(engine.shouldPulseHaptic(for: id, at: 0))
        XCTAssertFalse(engine.shouldPulseHaptic(for: id, at: 0.1))
        XCTAssertFalse(engine.shouldPulseHaptic(for: id, at: config.hapticRefractoryInterval - 0.01))
        XCTAssertTrue(engine.shouldPulseHaptic(for: id, at: config.hapticRefractoryInterval))
    }

    func testDifferentClustersPulseIndependently() {
        var engine = engine()
        add(&engine, at: WallPoint(x: 0, y: 0))
        add(&engine, at: WallPoint(x: 0.5, y: 0), timestamp: Fixture.baseTimestamp + 1)
        XCTAssertTrue(engine.shouldPulseHaptic(for: engine.clusters[0].id, at: 0))
        XCTAssertTrue(engine.shouldPulseHaptic(for: engine.clusters[1].id, at: 0))
    }

    // MARK: - Derived

    func testCoveredBoundsSpanEveryCluster() throws {
        var engine = engine()
        add(&engine, at: WallPoint(x: -0.3, y: 0.2))
        add(&engine, at: WallPoint(x: 0.4, y: -0.1), timestamp: Fixture.baseTimestamp + 1)
        let bounds = try XCTUnwrap(engine.coveredBounds)
        XCTAssertLessThanOrEqual(bounds.minX, -0.3)
        XCTAssertGreaterThanOrEqual(bounds.maxX, 0.4)
    }

    func testCoveredBoundsAreNilWithNoClusters() {
        XCTAssertNil(engine().coveredBounds)
    }

    func testStrengthBandsAreDerivedFromScore() {
        XCTAssertEqual(AnomalyStrengthBand.band(forScore: 0.1), .low)
        XCTAssertEqual(AnomalyStrengthBand.band(forScore: 0.6), .moderate)
        XCTAssertEqual(AnomalyStrengthBand.band(forScore: 0.9), .strong)
    }

    func testAccessibilityDescriptionNamesTheMeasurementNotAnObject() {
        let cluster = Fixture.cluster()
        let description = cluster.accessibilityDescription
        XCTAssertTrue(description.contains(SafetyCopy.anomalyLabel))
        for banned in ["wire", "screw", "stud", "pipe", "nail", "safe"] {
            XCTAssertFalse(description.lowercased().contains(banned),
                           "cluster description must not contain \(banned)")
        }
    }
}

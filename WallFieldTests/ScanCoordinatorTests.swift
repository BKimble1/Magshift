import XCTest
@testable import WallField

@MainActor
final class ScanCoordinatorTests: XCTestCase {

    private var field: ControllableFieldService!
    private var spatial: FakeSpatialProvider!
    private var store: InMemoryScanStore!
    private var preferences: AppPreferences!
    private var clock: ManualClock!

    override func setUp() {
        super.setUp()
        field = ControllableFieldService()
        spatial = FakeSpatialProvider()
        store = InMemoryScanStore()
        preferences = AppPreferences(defaults: Self.scratchDefaults())
        clock = ManualClock(start: Fixture.baseTimestamp)
    }

    private static func scratchDefaults() -> UserDefaults {
        let name = "wallfield.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeCoordinator() -> ScanCoordinator {
        ScanCoordinator(
            fieldService: field,
            spatialProvider: spatial,
            preferences: preferences,
            scanStore: store,
            feedback: FeedbackController(),
            capabilities: .simulated(),
            isSimulated: false,
            simulatedEnvironment: nil,
            clock: clock
        )
    }

    /// Emits a run of samples and lets the coordinator drain them.
    private func feed(
        count: Int,
        from index: Int = 0,
        magnitude: (Int) -> Double
    ) async {
        for offset in 0..<count {
            let i = index + offset
            let timestamp = Fixture.baseTimestamp + Double(i) * 0.02
            spatial.advance(to: timestamp)
            clock.set(timestamp)
            field.emit(Fixture.sample(
                magnitude: magnitude(i),
                at: timestamp,
                interval: i == 0 ? 0 : 0.02,
                source: .calibratedDeviceMotion
            ))
        }
        // Everything under test runs on the main actor, so yielding lets the
        // coordinator's consuming task drain the stream. The budget is generous
        // and bounded; no wall-clock sleeping is involved.
        for _ in 0..<(count * 4 + 100) {
            await Task.yield()
        }
    }

    // MARK: - Lifecycle

    func testStartsInPreparationWithNoHardwareRunning() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.phase, .preparing)
        XCTAssertFalse(field.isRunning)
        XCTAssertFalse(spatial.isRunning)
    }

    func testBeginningTheSessionStartsBothTheCameraAndTheSensor() {
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        XCTAssertEqual(coordinator.phase, .mappingWall)
        XCTAssertTrue(field.isRunning)
        XCTAssertTrue(spatial.isRunning)
    }

    func testASessionProblemBlocksInsteadOfStarting() {
        spatial.problem = .cameraAccessDenied
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        XCTAssertEqual(coordinator.phase, .blocked(.cameraAccessDenied))
        XCTAssertFalse(field.isRunning)
    }

    func testTeardownStopsEverything() {
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        coordinator.teardown()
        XCTAssertFalse(field.isRunning)
        XCTAssertEqual(field.stopCount, 1)
        XCTAssertEqual(spatial.stopCount, 1)
    }

    func testTeardownIsIdempotent() {
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        coordinator.teardown()
        coordinator.teardown()
        XCTAssertFalse(field.isRunning)
    }

    func testBackgroundingPausesAnActiveScan() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        XCTAssertEqual(coordinator.phase, .scanning)
        coordinator.handleBackgrounding()
        XCTAssertEqual(coordinator.phase, .paused)
    }

    // MARK: - Wall locking

    func testLockingTheTargetedWall() {
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        coordinator.lockTargetedWall()
        XCTAssertEqual(coordinator.phase, .wallLocked)
        XCTAssertNotNil(coordinator.lockedWall)
    }

    func testLockingWithNothingTargetedReportsWhy() {
        spatial.targetedWallID = nil
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        coordinator.lockTargetedWall()
        XCTAssertEqual(coordinator.phase, .mappingWall)
        XCTAssertEqual(coordinator.obstruction, .noWallIntersection)
    }

    func testUnlockingDiscardsTheBaseline() async {
        let coordinator = await calibratedCoordinator()
        XCTAssertNotNil(coordinator.calibration)
        coordinator.unlockWall()
        XCTAssertNil(coordinator.calibration)
        XCTAssertEqual(coordinator.phase, .mappingWall)
    }

    // MARK: - Calibration

    func testCalibrationCompletesAndArmsTheDetector() async {
        let coordinator = await calibratedCoordinator()
        XCTAssertEqual(coordinator.phase, .wallLocked)
        let calibration = coordinator.calibration
        XCTAssertNotNil(calibration)
        XCTAssertEqual(calibration?.baselineMagnitude ?? 0, 48, accuracy: 0.3)
        XCTAssertEqual(coordinator.calibrationProgress, 1, accuracy: 1e-9)
    }

    func testCalibrationIsRefusedWhenTrackingIsLimited() async {
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        coordinator.lockTargetedWall()
        spatial.trackingQuality = .limited(.excessiveMotion)
        coordinator.startCalibration()
        await feed(count: 20) { _ in 48 }
        XCTAssertEqual(coordinator.calibrationRejection, .trackingNotNormal)
        XCTAssertNil(coordinator.calibration)
        XCTAssertEqual(coordinator.phase, .wallLocked)
    }

    func testScanningCannotStartWithoutABaseline() {
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        coordinator.lockTargetedWall()
        coordinator.startScanning()
        XCTAssertEqual(coordinator.phase, .wallLocked, "scanning must require a baseline")
    }

    // MARK: - Scanning

    func testAnAnomalyBecomesAClusterAndIsRendered() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        await feed(count: 60, from: 200) { $0 < 220 ? 48 : 58 }
        XCTAssertFalse(coordinator.clusters.isEmpty, "a sustained 10 uT change produced no cluster")
        XCTAssertEqual(coordinator.clusters.first?.confidence, .unconfirmed)
        XCTAssertFalse(spatial.renderedClusterIDs.isEmpty)
    }

    func testAQuietWallProducesNothing() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        await feed(count: 400, from: 200) { _ in 48 }
        XCTAssertTrue(coordinator.clusters.isEmpty)
        XCTAssertNil(coordinator.obstruction)
    }

    func testReadingsWithNoMatchingPoseAreNotAnchored() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        spatial.hasPose = false
        await feed(count: 60, from: 200) { $0 < 220 ? 48 : 58 }
        XCTAssertTrue(coordinator.clusters.isEmpty,
                      "a reading with no pose close enough in time must not be placed")
    }

    func testMovingTooFastBlocksPlacementAndSaysSo() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        spatial.cameraSpeed = 5
        await feed(count: 60, from: 200) { $0 < 220 ? 48 : 58 }
        XCTAssertTrue(coordinator.clusters.isEmpty)
        XCTAssertEqual(coordinator.obstruction, .movingTooFast)
    }

    func testUndoRemovesTheMarkerFromTheScene() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        await feed(count: 60, from: 200) { $0 < 220 ? 48 : 58 }
        let count = coordinator.clusters.count
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(coordinator.undoLastCluster())
        XCTAssertEqual(coordinator.clusters.count, count - 1)
        XCTAssertEqual(spatial.removedClusterIDs.count, 1)
    }

    func testResetClearsMarkersButKeepsTheWallAndBaseline() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        await feed(count: 60, from: 200) { $0 < 220 ? 48 : 58 }
        coordinator.resetMeasurements()
        XCTAssertTrue(coordinator.clusters.isEmpty)
        XCTAssertNotNil(coordinator.lockedWall)
        XCTAssertNotNil(coordinator.calibration)
        XCTAssertEqual(coordinator.passIndex, 0)
        XCTAssertEqual(spatial.clearedMarkerCount, 1)
    }

    func testPauseAndResume() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        coordinator.pause()
        XCTAssertEqual(coordinator.phase, .paused)
        coordinator.resume()
        XCTAssertEqual(coordinator.phase, .scanning)
    }

    func testASecondPassOverTheSameSpotRaisesConfidence() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        await feed(count: 60, from: 200) { $0 < 220 ? 48 : 58 }
        XCTAssertEqual(coordinator.clusters.first?.confidence, .unconfirmed)

        coordinator.beginNewPass()
        XCTAssertEqual(coordinator.passIndex, 1)
        // A later pass, far enough after the first for it to count as new
        // evidence rather than the same sweep.
        await feed(count: 60, from: 400) { $0 < 420 ? 48 : 58 }
        XCTAssertEqual(coordinator.clusters.first?.confidence, .repeated)
        XCTAssertEqual(coordinator.clusters.first?.passCount, 2)
    }

    // MARK: - Finish and save

    func testFinishBuildsACompleteDraft() async throws {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        await feed(count: 60, from: 200) { $0 < 220 ? 48 : 58 }
        coordinator.finish()
        XCTAssertEqual(coordinator.phase, .finished)

        let draft = try XCTUnwrap(coordinator.draftRecord)
        XCTAssertEqual(draft.schemaVersion, ScanRecord.currentSchemaVersion)
        XCTAssertEqual(draft.algorithmVersion, AlgorithmVersion.current)
        XCTAssertEqual(draft.sensitivity, preferences.sensitivity)
        XCTAssertEqual(draft.detectorConfiguration, coordinator.configuration)
        XCTAssertFalse(draft.isSimulated)
        XCTAssertFalse(draft.clusters.isEmpty)
        XCTAssertFalse(draft.measurements.isEmpty)
        XCTAssertGreaterThan(draft.quality.candidatesProduced, 0)
        XCTAssertGreaterThan(draft.quality.measuredSampleRate, 0)
        XCTAssertEqual(draft.wall.frame, Fixture.wallFrame)
        XCTAssertNotNil(draft.wall.coveredBounds)
    }

    func testFinishWithoutABaselineIsBlockedRatherThanSavingRubbish() {
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        coordinator.lockTargetedWall()
        coordinator.finish()
        guard case .blocked = coordinator.phase else {
            return XCTFail("finishing without a baseline must not produce a record")
        }
        XCTAssertNil(coordinator.draftRecord)
    }

    func testSavePersistsTheUsersEdits() async throws {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        await feed(count: 60, from: 200) { $0 < 220 ? 48 : 58 }
        coordinator.finish()

        let saved = await coordinator.save(
            name: "  Hall, west wall  ",
            notes: "Two passes.",
            tags: ["control"]
        )
        XCTAssertTrue(saved)
        XCTAssertNil(coordinator.saveError)

        let result = await store.load()
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.name, "Hall, west wall")
        XCTAssertEqual(result.records.first?.notes, "Two passes.")
        XCTAssertEqual(result.records.first?.validationTags, ["control"])
        XCTAssertEqual(preferences.scanCounter, 1)
    }

    func testDiscardingLeavesNothingBehind() async {
        let coordinator = await calibratedCoordinator()
        coordinator.startScanning()
        await feed(count: 60, from: 200) { $0 < 220 ? 48 : 58 }
        coordinator.finish()
        coordinator.discardDraft()
        XCTAssertNil(coordinator.draftRecord)
        let result = await store.load()
        XCTAssertTrue(result.records.isEmpty)
    }

    // MARK: - Helpers

    /// A coordinator that has started, locked a wall and calibrated.
    private func calibratedCoordinator() async -> ScanCoordinator {
        let coordinator = makeCoordinator()
        coordinator.beginSession()
        coordinator.lockTargetedWall()
        coordinator.startCalibration()
        await feed(count: 200) { _ in 48 }
        return coordinator
    }
}

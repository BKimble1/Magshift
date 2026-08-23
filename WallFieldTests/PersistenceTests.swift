import XCTest
@testable import WallField

final class ScanRecordCodingTests: XCTestCase {

    private func roundTrip(_ record: ScanRecord) throws -> ScanRecord {
        let data = try ScanCoding.makeEncoder(prettyPrinted: false).encode(record)
        return try ScanCoding.makeDecoder().decode(ScanRecord.self, from: data)
    }

    func testFullRecordRoundTrips() throws {
        let record = Fixture.scanRecord(
            clusters: [Fixture.cluster(), Fixture.cluster(at: WallPoint(x: -0.3, y: 0.05), passes: [0, 1])],
            measurements: [measurement()]
        )
        let decoded = try roundTrip(record)
        XCTAssertEqual(decoded, record)
    }

    func testDatesSurviveToTheMillisecond() throws {
        var record = Fixture.scanRecord()
        record.createdAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let decoded = try roundTrip(record)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970,
                       record.createdAt.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testSchemaVersionIsWritten() throws {
        let data = try ScanCoding.makeEncoder(prettyPrinted: false).encode(Fixture.scanRecord())
        XCTAssertEqual(ScanCoding.peekSchemaVersion(in: data), ScanRecord.currentSchemaVersion)
    }

    func testPeekingAVersionFromNonsenseIsNil() {
        XCTAssertNil(ScanCoding.peekSchemaVersion(in: Data("not json".utf8)))
        XCTAssertNil(ScanCoding.peekSchemaVersion(in: Data()))
    }

    func testDecoderAcceptsADateWithoutFractionalSeconds() throws {
        // A file produced by any reasonable ISO-8601 writer must still open.
        var data = try ScanCoding.makeEncoder(prettyPrinted: false).encode(Fixture.scanRecord())
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: ".000Z", with: "Z")
        data = Data(text.utf8)
        XCTAssertNoThrow(try ScanCoding.makeDecoder().decode(ScanRecord.self, from: data))
    }

    func testMigrationSanitisesAHostileConfiguration() throws {
        var record = Fixture.scanRecord()
        record.schemaVersion = 0
        record.detectorConfiguration.enterZScore = -99
        let migrated = record.migrated()
        XCTAssertEqual(migrated.schemaVersion, ScanRecord.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(migrated.detectorConfiguration.enterZScore, 1)
    }

    func testConfigurationDecodingToleratesMissingKeys() throws {
        // A scan written by an older build that did not have every tunable must
        // still open, using the current default for anything absent.
        let json = Data(#"{"enterZScore": 6.5}"#.utf8)
        let config = try JSONDecoder().decode(DetectorConfiguration.self, from: json)
        XCTAssertEqual(config.enterZScore, 6.5)
        XCTAssertEqual(config.persistenceWindow, DetectorConfiguration.default.persistenceWindow)
        XCTAssertEqual(config.clusterRadius, DetectorConfiguration.default.clusterRadius)
    }

    func testNoAnomalyRecordIsFlaggedAsSuch() {
        let record = Fixture.scanRecord(clusters: [])
        XCTAssertTrue(record.hasNoAnomalies)
        XCTAssertEqual(record.clusterCount, 0)
    }

    func testCountsSplitConfirmedFromUnconfirmed() {
        let record = Fixture.scanRecord(clusters: [
            Fixture.cluster(passes: [0]),
            Fixture.cluster(at: WallPoint(x: 0.3, y: 0), passes: [0, 1]),
            Fixture.cluster(at: WallPoint(x: -0.3, y: 0), passes: [0, 2, 3]),
        ])
        XCTAssertEqual(record.clusterCount, 3)
        XCTAssertEqual(record.repeatedClusterCount, 2)
        XCTAssertEqual(record.unconfirmedClusterCount, 1)
    }

    func testDisplayNameFallsBackToTheDate() {
        var record = Fixture.scanRecord(name: "   ")
        record.name = "   "
        XCTAssertTrue(record.displayName.hasPrefix("Scan "))
    }

    func testSummaryBoundsPreferTheCoveredRegion() {
        let record = Fixture.scanRecord(clusters: [Fixture.cluster(at: WallPoint(x: 0.1, y: 0.1))])
        XCTAssertLessThan(record.summaryBounds.width, record.wall.displayBounds.width)
    }

    private func measurement() -> StoredMeasurement {
        StoredMeasurement(
            id: UUID(),
            timestamp: Fixture.baseTimestamp,
            elapsed: 4.25,
            field: Vector3(x: 12, y: -8, z: 45),
            magnitude: 47.5,
            delta: 9.5,
            robustZScore: 14,
            score: 0.72,
            gradient: 3.4,
            persistence: 4,
            accuracy: .high,
            source: .simulated,
            timingError: 0.018,
            trackingQuality: .normal,
            raycastQuality: .planeGeometry,
            wallPoint: WallPoint(x: 0.1, y: 0.2),
            worldPosition: Vector3(x: 0.1, y: 0.2, z: 0),
            wallDistance: 0.09,
            cameraSpeed: 0.14,
            passIndex: 0,
            clusterID: UUID()
        )
    }
}

final class FileScanStoreTests: XCTestCase {

    private lazy var directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallFieldStoreTests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> FileScanStore {
        try FileScanStore(containerDirectory: directory)
    }

    private var scansDirectory: URL {
        directory.appendingPathComponent("Scans", isDirectory: true)
    }

    func testSaveThenLoad() async throws {
        let store = try makeStore()
        let record = Fixture.scanRecord()
        try await store.save(record)
        let result = await store.load()
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.id, record.id)
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testSavingTwiceReplacesRatherThanDuplicates() async throws {
        let store = try makeStore()
        var record = Fixture.scanRecord()
        try await store.save(record)
        record.name = "Renamed"
        try await store.save(record)
        let result = await store.load()
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.name, "Renamed")
    }

    func testRecordsComeBackNewestFirst() async throws {
        let store = try makeStore()
        var older = Fixture.scanRecord(name: "Older")
        older.createdAt = Date(timeIntervalSince1970: 1_600_000_000)
        var newer = Fixture.scanRecord(name: "Newer")
        newer.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.save(older)
        try await store.save(newer)
        let result = await store.load()
        XCTAssertEqual(result.records.map(\.name), ["Newer", "Older"])
    }

    func testDelete() async throws {
        let store = try makeStore()
        let record = Fixture.scanRecord()
        try await store.save(record)
        try await store.delete(id: record.id)
        let result = await store.load()
        XCTAssertTrue(result.records.isEmpty)
    }

    func testDeletingSomethingThatIsNotThereThrows() async throws {
        let store = try makeStore()
        do {
            try await store.delete(id: UUID())
            XCTFail("expected a not-found error")
        } catch {
            XCTAssertTrue(error is ScanStoreError)
        }
    }

    func testCorruptedFileIsReportedNotSwallowed() async throws {
        let store = try makeStore()
        try await store.save(Fixture.scanRecord())
        try Data("{ this is not a scan".utf8)
            .write(to: scansDirectory.appendingPathComponent("broken.json"))

        let result = await store.load()
        XCTAssertEqual(result.records.count, 1, "the healthy scan must still load")
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertEqual(result.problems.first?.kind, .corrupted)
        XCTAssertEqual(result.problems.first?.id, "broken.json")
    }

    func testFutureVersionIsReportedAndNotDecoded() async throws {
        let store = try makeStore()
        let future = #"{"schemaVersion": 99, "somethingNew": true}"#
        try Data(future.utf8).write(to: scansDirectory.appendingPathComponent("future.json"))
        let result = await store.load()
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.problems.first?.kind, .futureVersion(99))
    }

    func testAProblemFileCanBeDeleted() async throws {
        let store = try makeStore()
        try Data("nonsense".utf8).write(to: scansDirectory.appendingPathComponent("bad.json"))
        try await store.deleteFile(named: "bad.json")
        let result = await store.load()
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testDeletingAFileOutsideTheStoreIsRefused() async throws {
        let store = try makeStore()
        do {
            try await store.deleteFile(named: "../escaped.json")
            XCTFail("a path escaping the store must be refused")
        } catch {
            XCTAssertTrue(error is ScanStoreError)
        }
    }

    func testNonJSONFilesAreIgnoredEntirely() async throws {
        let store = try makeStore()
        try Data("ignore me".utf8).write(to: scansDirectory.appendingPathComponent("notes.txt"))
        let result = await store.load()
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testDeleteAll() async throws {
        let store = try makeStore()
        try await store.save(Fixture.scanRecord())
        try await store.save(Fixture.scanRecord())
        try await store.deleteAll()
        let result = await store.load()
        XCTAssertTrue(result.records.isEmpty)
    }

    func testLoadingAnEmptyStoreIsNotAnError() async throws {
        let store = try makeStore()
        let result = await store.load()
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.problems.isEmpty)
    }
}

final class InMemoryScanStoreTests: XCTestCase {

    func testSeededRecordsAreReturned() async {
        let record = Fixture.scanRecord()
        let store = InMemoryScanStore(seed: [record])
        let result = await store.load()
        XCTAssertEqual(result.records.first?.id, record.id)
    }

    func testDeleteRemoves() async throws {
        let record = Fixture.scanRecord()
        let store = InMemoryScanStore(seed: [record])
        try await store.delete(id: record.id)
        let result = await store.load()
        XCTAssertTrue(result.records.isEmpty)
    }
}

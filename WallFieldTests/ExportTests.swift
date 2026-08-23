import XCTest
@testable import WallField

final class ScanExporterTests: XCTestCase {

    private func record() -> ScanRecord {
        Fixture.scanRecord(
            clusters: [
                Fixture.cluster(),
                Fixture.cluster(at: WallPoint(x: -0.2, y: 0.4), passes: [0, 1], peakDelta: -14),
            ],
            measurements: [],
            name: "Hall, west wall"
        )
    }

    private func dataRows(_ csv: String) -> [String] {
        csv.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }

    // MARK: - Safety travelling with the data

    func testEveryExportedFileCarriesTheLimitation() throws {
        let files = try ScanExporter.files(for: record())
        XCTAssertEqual(files.count, 3)
        for file in files {
            let text = String(decoding: file.contents, as: UTF8.self)
            XCTAssertTrue(text.contains(SafetyCopy.canonicalStatement),
                          "\(file.fileName) does not carry the canonical limitation statement")
        }
    }

    func testCSVPreambleIsCommentedSoTheHeaderRowIsStillFirstData() throws {
        let csv = ScanExporter.measurementsCSV(for: record())
        let lines = csv.split(separator: "\n").map(String.init)
        let firstNonComment = try XCTUnwrap(lines.first { !$0.hasPrefix("#") })
        XCTAssertEqual(firstNonComment, ScanExporter.measurementColumns.joined(separator: ","))
    }

    func testEveryPreambleLineIsCommented() {
        var scan = record()
        scan.name = "Kitchen\nsecond line"
        scan.notes = "note\nwith a break"
        let preamble = ScanExporter.csvPreamble(for: scan)
        for line in preamble.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("#"), "uncommented preamble line: \(line)")
        }
    }

    func testSimulatedScansSaySo() {
        let csv = ScanExporter.clustersCSV(for: Fixture.scanRecord(isSimulated: true))
        XCTAssertTrue(csv.contains("SIMULATED DATA"))
    }

    func testRealScansDoNotClaimToBeSimulated() {
        let csv = ScanExporter.clustersCSV(for: Fixture.scanRecord(isSimulated: false))
        XCTAssertFalse(csv.contains("SIMULATED DATA"))
    }

    // MARK: - Shape

    func testClusterRowsMatchTheColumnCount() {
        let csv = ScanExporter.clustersCSV(for: record())
        let rows = dataRows(csv)
        XCTAssertEqual(rows.count, 3, "one header plus two clusters")
        for row in rows {
            XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count,
                           ScanExporter.clusterColumns.count)
        }
    }

    func testMeasurementRowsMatchTheColumnCount() {
        let measurement = StoredMeasurement(
            id: UUID(), timestamp: 10_000, elapsed: 1.5,
            field: Vector3(x: 1, y: 2, z: 3), magnitude: 3.74, delta: 8,
            robustZScore: 12, score: 0.6, gradient: 2, persistence: 4,
            accuracy: .high, source: .simulated, timingError: 0.01,
            trackingQuality: .limited(.excessiveMotion), raycastQuality: .extrapolatedPlane,
            wallPoint: WallPoint(x: 0.1, y: 0.2),
            worldPosition: Vector3(x: 0.1, y: 0.2, z: 0),
            wallDistance: 0.09, cameraSpeed: 0.2, passIndex: 1, clusterID: UUID()
        )
        let scan = Fixture.scanRecord(clusters: [], measurements: [measurement])
        let rows = dataRows(ScanExporter.measurementsCSV(for: scan))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].split(separator: ",", omittingEmptySubsequences: false).count,
                       ScanExporter.measurementColumns.count)
        XCTAssertTrue(rows[1].contains("limited_excessiveMotion"))
        XCTAssertTrue(rows[1].contains("extrapolatedPlane"))
    }

    func testClusterRowsCarryTheMeasurementLabelNotAnObjectName() {
        let csv = ScanExporter.clustersCSV(for: record())
        XCTAssertTrue(csv.contains(SafetyCopy.anomalyLabel))
        for banned in ["wire", "screw", "stud", "pipe", "rebar"] {
            XCTAssertFalse(csv.lowercased().contains(banned))
        }
    }

    func testConfidenceAndPassesAreExported() {
        let csv = ScanExporter.clustersCSV(for: record())
        XCTAssertTrue(csv.contains("unconfirmed"))
        XCTAssertTrue(csv.contains("repeated"))
    }

    // MARK: - Escaping

    func testCommasAndQuotesAreEscapedToRFC4180() {
        XCTAssertEqual(ScanExporter.escape("plain"), "plain")
        XCTAssertEqual(ScanExporter.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(ScanExporter.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ScanExporter.escape("line\nbreak"), "\"line\nbreak\"")
    }

    func testAHostileScanNameCannotBreakTheCSVShape() {
        var scan = record()
        scan.name = "Kitchen, \"north\" wall\nsecond line"
        let rows = dataRows(ScanExporter.clustersCSV(for: scan))
        for row in rows {
            XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count,
                           ScanExporter.clusterColumns.count)
        }
    }

    func testFileNamesAreFilesystemSafe() throws {
        var scan = record()
        scan.name = "Hall / west \"wall\": 2024?"
        let files = try ScanExporter.files(for: scan)
        for file in files {
            XCTAssertFalse(file.fileName.contains("/"))
            XCTAssertFalse(file.fileName.contains("\""))
            XCTAssertFalse(file.fileName.contains(":"))
            XCTAssertFalse(file.fileName.contains("?"))
        }
    }

    func testAnUnnamedScanStillGetsAFileName() throws {
        var scan = record()
        scan.name = "!!!"
        let files = try ScanExporter.files(for: scan)
        XCTAssertTrue(files.allSatisfy { $0.fileName.hasPrefix("scan") })
    }

    // MARK: - JSON

    func testJSONEnvelopeIsVersionedAndCarriesTheNotice() throws {
        let data = try ScanExporter.json(for: record())
        let envelope = try ScanCoding.makeDecoder().decode(ScanExporter.Envelope.self, from: data)
        XCTAssertEqual(envelope.format, ScanExporter.jsonFormatIdentifier)
        XCTAssertEqual(envelope.notice, SafetyCopy.canonicalStatement)
        XCTAssertEqual(envelope.scan.clusters.count, 2)
        XCTAssertEqual(envelope.algorithmVersion, AlgorithmVersion.current)
    }

    func testJSONRoundTripsTheWholeScan() throws {
        let original = record()
        let data = try ScanExporter.json(for: original)
        let envelope = try ScanCoding.makeDecoder().decode(ScanExporter.Envelope.self, from: data)
        XCTAssertEqual(envelope.scan, original)
    }

    // MARK: - Writing

    func testFilesAreWrittenToAPrivateTemporaryDirectory() throws {
        let files = try ScanExporter.files(for: record())
        let written = try ScanExporter.writeToTemporaryDirectory(files)
        defer { try? FileManager.default.removeItem(at: written.directory) }
        XCTAssertEqual(written.urls.count, files.count)
        for url in written.urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertEqual(Set(written.urls.map { $0.deletingLastPathComponent() }).count, 1)
    }
}

final class DiagnosticsExporterTests: XCTestCase {

    private func run(samples: Int = 3, calibrated: Bool = true) -> DiagnosticRun {
        DiagnosticRun(
            id: UUID(),
            label: "Control region, case off",
            notes: "Two passes at 9 cm.",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_030),
            appVersion: "1.0.0 (1)",
            algorithmVersion: AlgorithmVersion.current,
            device: DeviceMetadata(
                model: "iPhone16,1", systemName: "iOS", systemVersion: "Version 18.0",
                supportsSceneDepth: false, supportsSceneReconstruction: false
            ),
            isSimulated: false,
            configuration: .default,
            calibration: calibrated ? Fixture.calibration() : nil,
            requestedSampleRate: 50,
            measuredSampleRate: 49.2,
            coreMotionClockOffset: 0.0004,
            samples: (0..<samples).map { index in
                DiagnosticSample(
                    id: UUID(),
                    timestamp: 10_000 + Double(index) * 0.02,
                    elapsed: Double(index) * 0.02,
                    x: 12, y: -8, z: 45, magnitude: 47.5,
                    smoothedMagnitude: 47.4, baseline: 48, delta: -0.6,
                    robustZScore: 3, sigma: 0.2, gradient: 0.4, persistence: 0,
                    detectorState: .idle, accuracy: .high, interval: 0.02,
                    source: .calibratedDeviceMotion,
                    userAcceleration: 0.01, rotationRate: 0.05,
                    trackingState: .normal, raycastDistance: 0.09
                )
            }
        )
    }

    func testCSVHasOneRowPerSamplePlusAHeader() {
        let csv = DiagnosticsExporter.csv(for: run(samples: 5))
        let rows = csv.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        XCTAssertEqual(rows.count, 6)
        for row in rows.dropFirst() {
            XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count,
                           DiagnosticsExporter.columns.count)
        }
    }

    func testPreambleRecordsTheMeasuredRateAndTheClockOffset() {
        let csv = DiagnosticsExporter.csv(for: run())
        XCTAssertTrue(csv.contains("Measured rate"))
        XCTAssertTrue(csv.contains("systemUptime - CoreMotion timestamp"))
        XCTAssertTrue(csv.contains("Baseline"))
    }

    func testPreambleSaysWhenThereWasNoBaseline() {
        let csv = DiagnosticsExporter.csv(for: run(calibrated: false))
        XCTAssertTrue(csv.contains("No baseline calibration was in force"))
    }

    func testJSONEnvelopeRoundTrips() throws {
        let original = run(samples: 4)
        let data = try DiagnosticsExporter.json(for: original)
        let envelope = try ScanCoding.makeDecoder()
            .decode(DiagnosticsExporter.Envelope.self, from: data)
        XCTAssertEqual(envelope.format, DiagnosticsExporter.jsonFormatIdentifier)
        XCTAssertEqual(envelope.run, original)
        XCTAssertEqual(envelope.notice, SafetyCopy.canonicalStatement)
    }

    func testMissingOptionalColumnsAreEmptyRatherThanZero() {
        var diagnosticRun = run(samples: 1)
        diagnosticRun.samples[0].raycastDistance = nil
        diagnosticRun.samples[0].trackingState = nil
        let csv = DiagnosticsExporter.csv(for: diagnosticRun)
        let dataRow = csv.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") }[1]
        XCTAssertTrue(dataRow.hasSuffix(","), "absent readings must be empty, not zero")
    }
}

final class FormatTests: XCTestCase {

    func testMicroteslaFormatting() {
        XCTAssertEqual(Format.microtesla(48.75), "48.8 \u{00B5}T")
        XCTAssertEqual(Format.microtesla(48.75, decimals: 2), "48.75 \u{00B5}T")
        XCTAssertEqual(Format.microtesla(.nan), "--")
    }

    func testSignedFormattingUsesATypographicMinus() {
        XCTAssertEqual(Format.signedMicrotesla(3.2), "+3.2 \u{00B5}T")
        XCTAssertEqual(Format.signedMicrotesla(-3.2), "\u{2212}3.2 \u{00B5}T")
    }

    func testDistanceSwitchesUnits() {
        XCTAssertEqual(Format.distance(0.09), "9 cm")
        XCTAssertEqual(Format.distance(1.25), "1.25 m")
    }

    func testDurationFormatting() {
        XCTAssertEqual(Format.duration(65), "1:05")
        XCTAssertEqual(Format.duration(3725), "1:02:05")
        XCTAssertEqual(Format.duration(-1), "--")
    }

    func testHertzRejectsNonsense() {
        XCTAssertEqual(Format.hertz(0), "--")
        XCTAssertEqual(Format.hertz(49.63), "49.6 Hz")
    }

    func testFileSlugStripsEverythingUnsafe() {
        XCTAssertEqual(Format.fileSlug("Hall / west \"wall\""), "Hall-west-wall")
        XCTAssertEqual(Format.fileSlug("!!!"), "scan")
        XCTAssertEqual(Format.fileSlug("", fallback: "run"), "run")
        XCTAssertLessThanOrEqual(Format.fileSlug(String(repeating: "a", count: 200)).count, 48)
    }
}

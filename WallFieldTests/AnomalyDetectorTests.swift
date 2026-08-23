import XCTest
@testable import WallField

final class AnomalyDetectorTests: XCTestCase {

    private func makeDetector(
        _ preset: SensitivityPreset = .medium,
        sigma: Double = 0.2,
        baseline: Double = 48
    ) -> OnlineAnomalyDetector {
        var detector = OnlineAnomalyDetector(configuration: .preset(preset))
        detector.adopt(calibration: Fixture.calibration(baseline: baseline, sigma: sigma))
        return detector
    }

    /// Runs a magnitude series through a detector and returns every candidate.
    @discardableResult
    private func run(
        _ detector: inout OnlineAnomalyDetector,
        count: Int,
        interval: TimeInterval = 0.02,
        magnitude: (Int) -> Double
    ) -> [AnomalyCandidate] {
        var candidates: [AnomalyCandidate] = []
        for sample in Fixture.stream(count: count, interval: interval, magnitude: magnitude) {
            if let candidate = detector.ingest(sample).candidate {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    // MARK: - Quiet field

    func testSteadyFieldProducesNoCandidates() {
        var detector = makeDetector()
        let noise = Fixture.noise(sigma: 0.2, count: 2000)
        let candidates = run(&detector, count: 2000) { 48.0 + noise[$0] }
        XCTAssertTrue(candidates.isEmpty,
                      "a quiet field produced \(candidates.count) false candidates")
    }

    func testUncalibratedDetectorEmitsNothing() {
        var detector = OnlineAnomalyDetector(configuration: .default)
        let candidates = run(&detector, count: 500) { $0 < 200 ? 48 : 90 }
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(detector.state, .uncalibrated)
        XCTAssertNil(detector.baseline)
        XCTAssertNil(detector.sigma)
    }

    func testInvalidatingCalibrationStopsDetection() {
        var detector = makeDetector()
        detector.invalidateCalibration()
        XCTAssertEqual(detector.state, .uncalibrated)
        let candidates = run(&detector, count: 300) { $0 < 100 ? 48 : 60 }
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Real changes

    func testPositiveStepIsDetected() throws {
        var detector = makeDetector()
        let candidates = run(&detector, count: 200) { $0 < 100 ? 48 : 56 }
        let first = try XCTUnwrap(candidates.first, "an 8 uT step was not detected")
        XCTAssertEqual(first.polarity, .positive)
        XCTAssertEqual(first.delta, 8, accuracy: 0.5)
        XCTAssertGreaterThan(first.robustZScore, 5)
        XCTAssertGreaterThanOrEqual(first.persistence, DetectorConfiguration.default.persistenceRequired)
    }

    func testNegativeStepIsDetected() throws {
        // Ferrous material can shield as well as concentrate the local field, so
        // a drop is as real a measurement as a rise.
        var detector = makeDetector()
        let candidates = run(&detector, count: 200) { $0 < 100 ? 48 : 40 }
        let first = try XCTUnwrap(candidates.first, "an 8 uT drop was not detected")
        XCTAssertEqual(first.polarity, .negative)
        XCTAssertLessThan(first.delta, -4)
    }

    func testGradientIsPositiveAcrossARisingEdge() {
        var detector = makeDetector()
        let candidates = run(&detector, count: 200) { index in
            index < 100 ? 48 : 48 + min(Double(index - 100) * 0.5, 10)
        }
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertGreaterThan(candidates[0].gradient, 0)
    }

    // MARK: - Isolated noise

    func testSingleSampleSpikeIsIgnored() {
        var detector = makeDetector()
        let candidates = run(&detector, count: 300) { $0 == 150 ? 88 : 48 }
        XCTAssertTrue(candidates.isEmpty, "one wild sample must never place a marker")
    }

    func testTwoSampleSpikeIsIgnored() {
        var detector = makeDetector()
        let candidates = run(&detector, count: 300) { (150...151).contains($0) ? 88 : 48 }
        XCTAssertTrue(candidates.isEmpty)
    }

    func testThreeSampleBurstIsAccepted() {
        // Median-of-three smoothing plus three-of-five persistence means the
        // shortest run of samples that can produce a candidate is three.
        var detector = makeDetector()
        let candidates = run(&detector, count: 300) { (150...152).contains($0) ? 60 : 48 }
        XCTAssertEqual(candidates.count, 1)
    }

    func testRepeatedTwoSampleBurstsNeverAccumulate() {
        // Sixty separate two-sample bursts, each far above the threshold. Sixty
        // chances for the persistence rule to leak, and it must not.
        var detector = makeDetector()
        let candidates = run(&detector, count: 600) { ($0 % 10) < 2 ? 88 : 48 }
        XCTAssertTrue(candidates.isEmpty,
                      "repeated short bursts produced \(candidates.count) candidates")
    }

    func testSpikeOnTheVeryFirstSamplesAfterCalibrationIsIgnored() {
        // Regression: with an empty median window the smoothing that rejects
        // isolated spikes is not yet in force, so a burst landing on the first
        // samples after calibration used to reach the persistence rule intact.
        var detector = makeDetector()
        let candidates = run(&detector, count: 300) { $0 < 2 ? 88 : 48 }
        XCTAssertTrue(candidates.isEmpty)
    }

    func testSubThresholdChangeProducesNothing() {
        // 3.5 uT is statistically enormous against 0.2 uT of noise but sits below
        // the absolute floor, which exists precisely so that an unusually quiet
        // room cannot promote a physically trivial wobble.
        var detector = makeDetector()
        let candidates = run(&detector, count: 400) { $0 < 100 ? 48 : 51.5 }
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Hysteresis and refractory

    func testHysteresisHoldsAnEventThroughADipBelowTheEntryThreshold() {
        var detector = makeDetector()
        // Rise well past the threshold...
        _ = run(&detector, count: 60) { $0 < 20 ? 48 : 56 }
        XCTAssertNotEqual(detector.state, .idle)

        // ...dip to +3 uT: below the 4 uT entry floor but above the 2.4 uT exit
        // floor, so the event must not end.
        for sample in Fixture.stream(count: 20, start: Fixture.baseTimestamp + 2, magnitude: { _ in 51 }) {
            _ = detector.ingest(sample)
        }
        XCTAssertNotEqual(detector.state, .idle, "a dip inside the hysteresis band ended the event")

        // ...then fall back to baseline, which must end it.
        for sample in Fixture.stream(count: 20, start: Fixture.baseTimestamp + 3, magnitude: { _ in 48 }) {
            _ = detector.ingest(sample)
        }
        XCTAssertEqual(detector.state, .idle)
    }

    func testRefractoryPeriodBoundsCandidatesForOneSustainedPeak() {
        var detector = makeDetector()
        // Two seconds of sustained anomaly at 50 Hz is 100 samples. Without a
        // refractory period this would emit dozens of candidates.
        let candidates = run(&detector, count: 150) { $0 < 50 ? 48 : 58 }
        let expectedUpperBound = Int(2.0 / DetectorConfiguration.default.refractoryInterval) + 2
        XCTAssertGreaterThanOrEqual(candidates.count, 3)
        XCTAssertLessThanOrEqual(candidates.count, expectedUpperBound)

        let gaps = zip(candidates, candidates.dropFirst()).map { $1.timestamp - $0.timestamp }
        for gap in gaps {
            XCTAssertGreaterThanOrEqual(
                gap, DetectorConfiguration.default.refractoryInterval - 1e-9,
                "candidates were emitted closer together than the refractory period"
            )
        }
    }

    // MARK: - Baseline adaptation

    func testSlowEnvironmentalDriftIsAbsorbedRatherThanReported() {
        // 0.1 uT per second for a minute: six microtesla of drift, well past the
        // absolute floor, but slow enough that the baseline should follow it.
        var detector = makeDetector()
        let candidates = run(&detector, count: 3000) { 48.0 + Double($0) * 0.02 * 0.1 }
        XCTAssertTrue(candidates.isEmpty,
                      "slow drift produced \(candidates.count) candidates")
        XCTAssertEqual(detector.baseline ?? 0, 48 + 6, accuracy: 1.0)
    }

    func testBaselineDoesNotAbsorbAnActiveAnomaly() {
        // If the baseline followed the anomaly, the reading would erase itself
        // and a long pass over one feature would stop reporting it.
        var detector = makeDetector()
        _ = run(&detector, count: 100) { _ in 48 }
        let baselineBefore = detector.baseline ?? 0
        _ = run(&detector, count: 500) { _ in 58 }
        let baselineAfter = detector.baseline ?? 0
        XCTAssertEqual(baselineAfter, baselineBefore, accuracy: 0.5,
                       "the baseline drifted into the anomaly")
    }

    // MARK: - Sensitivity

    func testSensitivityPresetsChangeOnlyTheThresholds() {
        // A three microtesla change: above the High preset's floor, below
        // Medium's and Low's.
        func candidateCount(_ preset: SensitivityPreset) -> Int {
            var detector = makeDetector(preset)
            return run(&detector, count: 300) { $0 < 100 ? 48 : 51 }.count
        }
        XCTAssertGreaterThan(candidateCount(.high), 0)
        XCTAssertEqual(candidateCount(.medium), 0)
        XCTAssertEqual(candidateCount(.low), 0)
    }

    func testEveryPresetDetectsALargeChange() {
        for preset in SensitivityPreset.allCases {
            var detector = makeDetector(preset)
            let candidates = run(&detector, count: 300) { $0 < 100 ? 48 : 68 }
            XCTAssertFalse(candidates.isEmpty, "\(preset.displayName) missed a 20 uT change")
        }
    }

    func testPresetsAreOrderedByStrictness() {
        let low = DetectorConfiguration.preset(.low)
        let medium = DetectorConfiguration.preset(.medium)
        let high = DetectorConfiguration.preset(.high)
        XCTAssertGreaterThan(low.enterZScore, medium.enterZScore)
        XCTAssertGreaterThan(medium.enterZScore, high.enterZScore)
        XCTAssertGreaterThan(low.absoluteFloorMicrotesla, medium.absoluteFloorMicrotesla)
        XCTAssertGreaterThan(medium.absoluteFloorMicrotesla, high.absoluteFloorMicrotesla)
        for preset in SensitivityPreset.allCases {
            let config = DetectorConfiguration.preset(preset)
            XCTAssertLessThan(config.exitZScore, config.enterZScore,
                              "\(preset.rawValue) has no hysteresis band")
            XCTAssertEqual(config.matchingPreset, preset)
        }
    }

    // MARK: - Robustness

    func testNonFiniteSamplesAreIgnored() {
        var detector = makeDetector()
        _ = run(&detector, count: 100) { _ in 48 }
        let broken = MagneticFieldSample(
            timestamp: .nan, x: .infinity, y: 0, z: 0,
            accuracy: .high, interval: 0.02, source: .simulated
        )
        let output = detector.ingest(broken)
        XCTAssertNil(output.candidate)
        XCTAssertNotEqual(detector.state, .uncalibrated)
    }

    func testCandidateScoreIsBoundedAndOrdered() {
        let config = DetectorConfiguration.default
        let small = Fixture.candidate(delta: 4.1, z: 5.1)
        let large = Fixture.candidate(delta: 40, z: 60)
        XCTAssertGreaterThanOrEqual(small.score(configuration: config), 0)
        XCTAssertLessThanOrEqual(large.score(configuration: config), 1)
        XCTAssertLessThan(small.score(configuration: config), large.score(configuration: config))
    }

    func testAdoptingCalibrationAppliesTheNoiseFloor() {
        var detector = OnlineAnomalyDetector(configuration: .default)
        detector.adopt(calibration: Fixture.calibration(sigma: 0.0001))
        XCTAssertEqual(detector.sigma ?? 0, DetectorConfiguration.default.minimumSigma, accuracy: 1e-12)
    }

    func testSanitizedConfigurationClampsNonsense() {
        var config = DetectorConfiguration.default
        config.enterZScore = -5
        config.exitZScore = 99
        config.persistenceRequired = 100
        config.persistenceWindow = 0
        config.minimumSigma = -1
        config.maximumWallDistance = 0
        let sane = config.sanitized()
        XCTAssertGreaterThanOrEqual(sane.enterZScore, 1)
        XCTAssertLessThanOrEqual(sane.exitZScore, sane.enterZScore)
        XCTAssertLessThanOrEqual(sane.persistenceRequired, sane.persistenceWindow)
        XCTAssertGreaterThan(sane.minimumSigma, 0)
        XCTAssertGreaterThan(sane.maximumWallDistance, sane.minimumWallDistance)
    }
}

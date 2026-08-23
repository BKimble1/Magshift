import XCTest
@testable import WallField

final class CalibrationEngineTests: XCTestCase {

    private let configuration = DetectorConfiguration.default

    /// Feeds samples until calibration reaches a terminal outcome.
    private func run(_ samples: [MagneticFieldSample],
                     tracking: TrackingQuality = .normal,
                     requireTracking: Bool = true) -> CalibrationProgress {
        var engine = CalibrationEngine(configuration: configuration)
        var last: CalibrationProgress = .collecting(fraction: 0, elapsed: 0, sampleCount: 0)
        for sample in samples {
            last = engine.ingest(sample, tracking: tracking, requireTracking: requireTracking)
            if last.isTerminal { return last }
        }
        return last
    }

    // MARK: - Success

    func testSteadyFieldProducesABaseline() {
        let noise = Fixture.noise(sigma: 0.15, count: 200)
        let samples = Fixture.stream(count: 200) { 48.0 + noise[$0] }
        guard case .completed(let summary) = run(samples) else {
            return XCTFail("a steady field should calibrate")
        }
        XCTAssertEqual(summary.baselineMagnitude, 48, accuracy: 0.2)
        XCTAssertGreaterThan(summary.sigma, 0)
        XCTAssertLessThan(summary.sigma, configuration.calibrationMaximumSigma)
        XCTAssertEqual(summary.worstAccuracy, .high)
        XCTAssertEqual(summary.measuredSampleRate, 50, accuracy: 1)
        XCTAssertGreaterThanOrEqual(summary.duration, configuration.calibrationMinimumDuration)
        XCTAssertGreaterThanOrEqual(summary.sampleCount, configuration.calibrationMinimumSamples)
    }

    func testSigmaIsDerivedFromTheMedianAbsoluteDeviation() {
        let noise = Fixture.noise(sigma: 0.4, count: 200)
        let samples = Fixture.stream(count: 200) { 48.0 + noise[$0] }
        guard case .completed(let summary) = run(samples) else {
            return XCTFail("expected a baseline")
        }
        XCTAssertEqual(
            summary.sigma,
            RobustStatistics.madToSigma * summary.medianAbsoluteDeviation,
            accuracy: 1e-9,
            "sigma must be exactly 1.4826 x MAD unless the floor applied"
        )
        XCTAssertFalse(summary.sigmaWasFloored)
    }

    func testPerfectlyQuietFieldIsFlooredRatherThanTrusted() {
        // A calibration that measures zero variance would make every later
        // sample infinitely significant. The learned noise floor prevents that.
        let samples = Fixture.stream(count: 200) { _ in 48.0 }
        guard case .completed(let summary) = run(samples) else {
            return XCTFail("expected a baseline")
        }
        XCTAssertEqual(summary.medianAbsoluteDeviation, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.sigma, configuration.minimumSigma, accuracy: 1e-12)
        XCTAssertTrue(summary.sigmaWasFloored)
    }

    // MARK: - Rejection

    func testNoisyFieldIsRejected() {
        let noise = Fixture.noise(sigma: 4, count: 300)
        let samples = Fixture.stream(count: 300) { 48.0 + noise[$0] }
        guard case .rejected(let reason) = run(samples) else {
            return XCTFail("an unsettled field must not produce a baseline")
        }
        XCTAssertEqual(reason, .fieldTooNoisy)
    }

    func testLowAccuracyIsRejectedImmediately() {
        let samples = Fixture.stream(count: 200, accuracy: .low) { _ in 48.0 }
        guard case .rejected(let reason) = run(samples) else {
            return XCTFail("low calibration accuracy must be refused")
        }
        XCTAssertEqual(reason, .accuracyTooLow)
    }

    func testUncalibratedAccuracyIsRejected() {
        let samples = Fixture.stream(count: 200, accuracy: .uncalibrated) { _ in 48.0 }
        guard case .rejected(let reason) = run(samples) else {
            return XCTFail("uncalibrated data must be refused")
        }
        XCTAssertEqual(reason, .accuracyTooLow)
    }

    func testRawMagnetometerSourceIsRejected() {
        let samples = Fixture.stream(count: 200, accuracy: .high, source: .rawMagnetometer) { _ in 48.0 }
        guard case .rejected(let reason) = run(samples) else {
            return XCTFail("raw magnetometer data must not anchor a scan")
        }
        XCTAssertEqual(reason, .unsupportedSource)
    }

    func testMovingPhoneIsRejected() {
        let moving = MotionEnergy(userAcceleration: 0.4, rotationRate: 1.2)
        let samples = Fixture.stream(count: 200, motion: moving) { _ in 48.0 }
        guard case .rejected(let reason) = run(samples) else {
            return XCTFail("a baseline collected while moving must be refused")
        }
        XCTAssertEqual(reason, .excessiveMotion)
    }

    func testLimitedTrackingIsRejectedWhenTrackingIsRequired() {
        let samples = Fixture.stream(count: 200) { _ in 48.0 }
        guard case .rejected(let reason) = run(samples, tracking: .limited(.excessiveMotion)) else {
            return XCTFail("limited tracking must refuse a scan calibration")
        }
        XCTAssertEqual(reason, .trackingNotNormal)
    }

    func testLimitedTrackingIsIgnoredWhenTrackingIsNotRequired() {
        // The diagnostics lab calibrates with no AR session at all.
        let samples = Fixture.stream(count: 200) { _ in 48.0 }
        let outcome = run(samples, tracking: .notAvailable, requireTracking: false)
        guard case .completed = outcome else {
            return XCTFail("diagnostics calibration must not depend on AR tracking")
        }
    }

    func testStallingSampleStreamIsRejected() {
        // 5 Hz is far below the rate the detector's timing assumptions need.
        let samples = Fixture.stream(count: 200, interval: 0.2) { _ in 48.0 }
        guard case .rejected(let reason) = run(samples) else {
            return XCTFail("an unhealthy sample stream must be refused")
        }
        XCTAssertEqual(reason, .sampleTimingUnstable)
    }

    func testLargeSwingIsRejectedAsRangeRatherThanAveraged() {
        // A field that sweeps across a wide range during calibration is not a
        // baseline, however tidy its median looks.
        let samples = Fixture.stream(count: 300) { index in
            48.0 + 9.0 * sin(Double(index) * 0.05)
        }
        guard case .rejected(let reason) = run(samples) else {
            return XCTFail("a swinging field must be refused")
        }
        XCTAssertTrue(reason == .fieldRangeTooLarge || reason == .fieldTooNoisy,
                      "expected a range or noise rejection, got \(reason)")
    }

    // MARK: - Progress and reset

    func testProgressAdvancesTowardsOne() {
        var engine = CalibrationEngine(configuration: configuration)
        var fractions: [Double] = []
        for sample in Fixture.stream(count: 60, magnitude: { _ in 48 }) {
            if case .collecting(let fraction, _, _) = engine.ingest(sample, tracking: .normal) {
                fractions.append(fraction)
            }
        }
        XCTAssertEqual(fractions.count, 60)
        XCTAssertTrue(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 },
                      "progress must be monotonic")
        XCTAssertLessThan(fractions.last ?? 1, 1)
    }

    func testRejectionResetsTheEngineSoTheNextAttemptStartsClean() {
        var engine = CalibrationEngine(configuration: configuration)
        for sample in Fixture.stream(count: 40, magnitude: { _ in 48 }) {
            _ = engine.ingest(sample, tracking: .normal)
        }
        XCTAssertGreaterThan(engine.sampleCount, 0)
        _ = engine.ingest(Fixture.sample(magnitude: 48, at: 0, accuracy: .low), tracking: .normal)
        XCTAssertEqual(engine.sampleCount, 0)
        XCTAssertEqual(engine.elapsed, 0)
    }

    func testRollingMedianMatchesTheDetectorsSmoothing() {
        let values = [1.0, 100.0, 1.0, 1.0, 1.0]
        let smoothed = CalibrationEngine.rollingMedian(values, window: 3)
        XCTAssertEqual(smoothed[0], 1)
        XCTAssertEqual(smoothed[1], 50.5)   // median of [1, 100]
        XCTAssertEqual(smoothed[2], 1)      // median of [1, 100, 1]
        XCTAssertEqual(smoothed[3], 1)
        XCTAssertEqual(smoothed[4], 1)
    }
}

import XCTest
@testable import WallField

final class RobustStatisticsTests: XCTestCase {

    func testMagnitudeIsEuclideanNorm() {
        let sample = MagneticFieldSample(
            timestamp: 0, x: 3, y: 4, z: 12,
            accuracy: .high, interval: 0.02, source: .simulated
        )
        XCTAssertEqual(sample.magnitude, 13, accuracy: 1e-9)
    }

    func testMagnitudeIsUnchangedByRotation() {
        // Detection runs on magnitude precisely so that turning the phone does
        // not look like a change in the field.
        let base = Fixture.sample(magnitude: 48, at: 0)
        let rotated = MagneticFieldSample(
            timestamp: 0, x: base.z, y: base.x, z: base.y,
            accuracy: .high, interval: 0.02, source: .simulated
        )
        XCTAssertEqual(base.magnitude, rotated.magnitude, accuracy: 1e-9)
    }

    func testMedianOfOddCount() {
        XCTAssertEqual(RobustStatistics.median([5, 1, 3]), 3)
    }

    func testMedianOfEvenCountAveragesTheMiddlePair() {
        XCTAssertEqual(RobustStatistics.median([1, 2, 3, 4]), 2.5)
    }

    func testMedianOfEmptyIsNil() {
        XCTAssertNil(RobustStatistics.median([]))
        XCTAssertNil(RobustStatistics.medianAbsoluteDeviation([]))
        XCTAssertNil(RobustStatistics.robustSigma([]))
        XCTAssertNil(RobustStatistics.mean([]))
        XCTAssertNil(RobustStatistics.range([]))
    }

    func testMedianOfSortedMatchesMedian() {
        let values = [9.0, 2.0, 7.0, 4.0, 1.0]
        XCTAssertEqual(RobustStatistics.medianOfSorted(values.sorted()),
                       RobustStatistics.median(values))
    }

    func testMedianAbsoluteDeviation() {
        // median = 3; deviations = [2,1,0,1,2]; median of those = 1.
        XCTAssertEqual(RobustStatistics.medianAbsoluteDeviation([1, 2, 3, 4, 5]), 1)
    }

    func testRobustSigmaAppliesTheStandardScaleFactor() {
        let sigma = RobustStatistics.robustSigma([1, 2, 3, 4, 5])
        XCTAssertEqual(sigma ?? 0, RobustStatistics.madToSigma, accuracy: 1e-9)
    }

    func testMedianIgnoresASingleWildOutlier() {
        // The reason robust statistics are used at all: one bad sample must not
        // move the centre or inflate the spread.
        let clean = [48.0, 48.1, 47.9, 48.05, 47.95]
        let contaminated = clean + [900.0]
        let cleanMedian = RobustStatistics.median(clean) ?? 0
        let contaminatedMedian = RobustStatistics.median(contaminated) ?? 0
        XCTAssertEqual(cleanMedian, contaminatedMedian, accuracy: 0.1)

        let cleanMean = RobustStatistics.mean(clean) ?? 0
        let contaminatedMean = RobustStatistics.mean(contaminated) ?? 0
        XCTAssertGreaterThan(abs(contaminatedMean - cleanMean), 100,
                             "the mean should be badly affected, which is why it is not used")
    }

    func testRobustZScoreIsZeroForNonPositiveSigma() {
        // A degenerate baseline must never make every sample infinitely
        // significant.
        XCTAssertEqual(RobustStatistics.robustZScore(value: 60, centre: 48, sigma: 0), 0)
        XCTAssertEqual(RobustStatistics.robustZScore(value: 60, centre: 48, sigma: -1), 0)
    }

    func testRobustZScoreIsSymmetric() {
        let up = RobustStatistics.robustZScore(value: 50, centre: 48, sigma: 0.5)
        let down = RobustStatistics.robustZScore(value: 46, centre: 48, sigma: 0.5)
        XCTAssertEqual(up, 4, accuracy: 1e-9)
        XCTAssertEqual(down, 4, accuracy: 1e-9)
    }
}

final class BoundedBufferTests: XCTestCase {

    func testDropsOldestWhenFull() {
        var buffer = BoundedBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        XCTAssertEqual(buffer.elements, [3, 4, 5])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertTrue(buffer.isFull)
    }

    func testStaysBoundedOverManyAppends() {
        var buffer = BoundedBuffer<Int>(capacity: 10)
        for value in 0..<10_000 { buffer.append(value) }
        XCTAssertEqual(buffer.count, 10)
        XCTAssertEqual(buffer.elements, Array(9_990..<10_000))
    }

    func testFirstAndLast() {
        var buffer = BoundedBuffer<Int>(capacity: 3)
        XCTAssertNil(buffer.first)
        XCTAssertNil(buffer.last)
        buffer.append(7)
        buffer.append(8)
        XCTAssertEqual(buffer.first, 7)
        XCTAssertEqual(buffer.last, 8)
    }

    func testFromEndCountsBackFromNewest() {
        var buffer = BoundedBuffer<Int>(capacity: 4)
        for value in 1...4 { buffer.append(value) }
        XCTAssertEqual(buffer.fromEnd(0), 4)
        XCTAssertEqual(buffer.fromEnd(3), 1)
        XCTAssertNil(buffer.fromEnd(4))
    }

    func testSuffixReturnsTheNewestElements() {
        var buffer = BoundedBuffer<Int>(capacity: 5)
        for value in 1...5 { buffer.append(value) }
        XCTAssertEqual(buffer.suffix(2), [4, 5])
        XCTAssertEqual(buffer.suffix(0), [])
        XCTAssertEqual(buffer.suffix(99), [1, 2, 3, 4, 5])
    }

    func testRemoveAll() {
        var buffer = BoundedBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.elements, [])
    }
}

final class RateLimiterTests: XCTestCase {

    func testAllowsAtMostOncePerInterval() {
        var limiter = RateLimiter(hz: 10)
        XCTAssertTrue(limiter.allow(at: 0))
        XCTAssertFalse(limiter.allow(at: 0.05))
        XCTAssertTrue(limiter.allow(at: 0.10))
        XCTAssertFalse(limiter.allow(at: 0.15))
    }

    func testThrottlesFiftyHertzToTenHertz() {
        var limiter = RateLimiter(hz: 10)
        var allowed = 0
        for index in 0..<500 where limiter.allow(at: Double(index) * 0.02) {
            allowed += 1
        }
        // 10 seconds of samples at 50 Hz publishes about 100 times. The exact
        // count depends on floating-point accumulation of the 0.02 s step, so
        // the assertion bounds it rather than pinning it.
        XCTAssertGreaterThanOrEqual(allowed, 80)
        XCTAssertLessThanOrEqual(allowed, 105)
    }

    func testBackwardsTimeResetsRatherThanBlockingForever() {
        var limiter = RateLimiter(hz: 10)
        XCTAssertTrue(limiter.allow(at: 100))
        XCTAssertTrue(limiter.allow(at: 1))
    }

    func testResetAllowsImmediately() {
        var limiter = RateLimiter(hz: 1)
        XCTAssertTrue(limiter.allow(at: 0))
        XCTAssertFalse(limiter.allow(at: 0.1))
        limiter.reset()
        XCTAssertTrue(limiter.allow(at: 0.1))
    }
}

import Foundation

/// Order statistics used by calibration and the online detector.
///
/// Robust estimators are used throughout rather than mean and standard
/// deviation. During a real calibration the user's hand shakes, a car passes,
/// someone walks by with a phone; a single large outlier moves the mean and
/// inflates the standard deviation enough to blind the detector for the rest of
/// the scan, while the median and MAD barely move.
enum RobustStatistics {

    /// Scale factor that makes `1.4826 * MAD` a consistent estimator of the
    /// standard deviation for normally distributed data.
    static let madToSigma = 1.4826

    /// Median. Returns `nil` for an empty input rather than a sentinel value.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Median of an already-sorted array. Avoids re-sorting in hot paths.
    static func medianOfSorted(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Median absolute deviation about the median.
    static func medianAbsoluteDeviation(_ values: [Double]) -> Double? {
        guard let centre = median(values) else { return nil }
        return median(values.map { abs($0 - centre) })
    }

    /// Robust standard-deviation estimate, `1.4826 * MAD`.
    ///
    /// This is intentionally *not* floored here. Flooring is a policy decision
    /// that belongs to the caller, which knows the configured noise floor.
    static func robustSigma(_ values: [Double]) -> Double? {
        guard let mad = medianAbsoluteDeviation(values) else { return nil }
        return madToSigma * mad
    }

    /// Arithmetic mean.
    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Peak-to-peak range.
    static func range(_ values: [Double]) -> Double? {
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        return maximum - minimum
    }

    /// Robust z-score of `value` given a centre and a sigma.
    ///
    /// `sigma` is expected to be already floored by the caller; a zero or
    /// negative sigma returns 0 rather than infinity, so a degenerate baseline
    /// can never make every sample look infinitely significant.
    static func robustZScore(value: Double, centre: Double, sigma: Double) -> Double {
        guard sigma > 0, value.isFinite, centre.isFinite else { return 0 }
        return abs(value - centre) / sigma
    }
}

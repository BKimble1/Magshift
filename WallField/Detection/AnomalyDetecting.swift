import Foundation

/// The anomaly detector's contract.
///
/// Deliberately a value type with a `mutating` entry point rather than a class:
/// the detector is pure arithmetic over a bounded window, it has no side effects,
/// no framework dependencies and no identity, which is exactly what makes it
/// exhaustively unit-testable with synthetic data.
protocol AnomalyDetecting {
    var configuration: DetectorConfiguration { get }
    /// Current state, including the transient refractory state.
    var state: DetectorState { get }
    /// The slow baseline currently in force, µT. `nil` before calibration.
    var baseline: Double? { get }
    /// The noise estimate currently in force, µT. `nil` before calibration.
    var sigma: Double? { get }

    /// Arms the detector with a completed calibration.
    mutating func adopt(calibration: CalibrationSummary)
    /// Returns the detector to its uncalibrated state, discarding all history.
    mutating func invalidateCalibration()
    /// Feeds one sample and returns everything derived from it.
    mutating func ingest(_ sample: MagneticFieldSample) -> DetectorOutput
}

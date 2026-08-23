import Foundation

/// The result of a successful baseline calibration, stored with the scan.
struct CalibrationSummary: Codable, Sendable, Hashable {
    /// Robust centre of the quiet field: the median magnitude, µT.
    var baselineMagnitude: Double
    /// Robust noise estimate: `1.4826 * MAD` of the magnitude, µT, floored at
    /// `DetectorConfiguration.minimumSigma`.
    var sigma: Double
    /// The MAD that `sigma` was derived from, before scaling and flooring, µT.
    /// `sigma == 1.4826 * medianAbsoluteDeviation` unless the floor applied.
    ///
    /// This is measured on the *smoothed* magnitude series, using the same
    /// median-of-N smoothing the online detector applies, so that a z-score
    /// computed during scanning is comparable to the noise measured during
    /// calibration rather than being conservative by an unknown factor.
    var medianAbsoluteDeviation: Double
    /// MAD of the raw, unsmoothed magnitudes, µT. Diagnostics and validation
    /// only; nothing in the detector uses it.
    var rawMedianAbsoluteDeviation: Double
    /// Whether `sigma` was raised to the configured floor.
    var sigmaWasFloored: Bool
    /// Peak-to-peak magnitude observed during calibration, µT.
    var range: Double
    /// Mean field vector during calibration, µT. Diagnostic only.
    var meanVector: Vector3
    /// Number of accepted samples.
    var sampleCount: Int
    /// Wall-clock seconds of accepted samples.
    var duration: TimeInterval
    /// Worst calibration accuracy seen among accepted samples.
    var worstAccuracy: MagneticFieldAccuracy
    /// Measured delivery rate during calibration.
    var measuredSampleRate: Double
    /// Which sensor produced the samples.
    var source: MagneticFieldSource
    /// When calibration completed.
    var completedAt: Date

    var isFloorLimited: Bool { sigmaWasFloored }

    /// A one-line summary for the review screen.
    var shortDescription: String {
        "Baseline \(Format.microtesla(baselineMagnitude)), noise \(Format.microtesla(sigma, decimals: 2))"
    }
}

/// Why a calibration attempt was refused.
///
/// Calibration is refused rather than degraded: a baseline measured while the
/// phone was moving, or while the sensor was uncalibrated, would poison every
/// reading that followed.
enum CalibrationRejection: String, Codable, Sendable, Hashable, CaseIterable {
    case notEnoughSamples
    case notEnoughDuration
    case accuracyTooLow
    case fieldTooNoisy
    case fieldRangeTooLarge
    case excessiveMotion
    case trackingNotNormal
    case sampleTimingUnstable
    case sensorUnavailable
    case unsupportedSource

    var headline: String {
        switch self {
        case .notEnoughSamples: return "Not enough sensor data"
        case .notEnoughDuration: return "Hold still a little longer"
        case .accuracyTooLow: return "Magnetic calibration needed"
        case .fieldTooNoisy: return "The field here is too unsettled"
        case .fieldRangeTooLarge: return "The field moved too much"
        case .excessiveMotion: return "Hold the phone still"
        case .trackingNotNormal: return "Camera tracking is not steady"
        case .sampleTimingUnstable: return "Sensor data is stalling"
        case .sensorUnavailable: return "Magnetic data unavailable"
        case .unsupportedSource: return "Reduced-quality sensor only"
        }
    }

    var recovery: String {
        switch self {
        case .notEnoughSamples:
            return "Keep the phone still and pointed at the wall while the baseline is collected."
        case .notEnoughDuration:
            return "Hold the phone steady for a few seconds without moving it."
        case .accuracyTooLow:
            return "Move the phone slowly in a figure-eight away from metal, then try again."
        case .fieldTooNoisy:
            return "Move away from chargers, speakers, tools and appliances, remove any magnetic accessory, and try again."
        case .fieldRangeTooLarge:
            return "Something nearby is changing the field. Remove magnetic accessories and hold the phone still."
        case .excessiveMotion:
            return "The phone was moving while the baseline was being collected. Rest it against the wall or brace your arm, then try again."
        case .trackingNotNormal:
            return "Improve lighting and hold the phone steady so the camera can keep tracking the wall."
        case .sampleTimingUnstable:
            return "Close other apps and try again. Sensor samples are not arriving reliably."
        case .sensorUnavailable:
            return "This device is not reporting magnetic-field data, so a scan is not possible."
        case .unsupportedSource:
            return "Calibrated magnetic data is unavailable on this device, so readings cannot be placed on the wall. Diagnostics still work."
        }
    }
}

import Foundation

/// How the field reading was obtained.
enum MagneticFieldSource: String, Codable, Sendable, CaseIterable {
    /// `CMDeviceMotion.magneticField` -- the total field around the device with
    /// device bias removed, plus a calibration-accuracy estimate. This is the
    /// only source used for anomaly detection.
    case calibratedDeviceMotion

    /// `CMMotionManager.magnetometerData` -- raw, bias-included. Offered only as
    /// a clearly labelled reduced-quality diagnostic fallback, never as the
    /// basis for a placed marker.
    case rawMagnetometer

    /// Deterministic synthetic data. Unreachable in a Release build, which
    /// cannot select `RuntimeMode.simulated`.
    case simulated

    var displayName: String {
        switch self {
        case .calibratedDeviceMotion: return "Calibrated (device motion)"
        case .rawMagnetometer: return "Raw magnetometer"
        case .simulated: return "Simulated"
        }
    }

    /// Whether readings from this source may anchor a marker on the wall.
    var isAcceptableForDetection: Bool {
        switch self {
        case .calibratedDeviceMotion: return true
        case .simulated: return true
        case .rawMagnetometer: return false
        }
    }
}

/// Mirrors `CMMagneticFieldCalibrationAccuracy` without leaking Core Motion
/// types into pure logic, so the detector can be unit tested with no framework
/// dependency.
enum MagneticFieldAccuracy: Int, Codable, Sendable, CaseIterable, Comparable {
    case uncalibrated = -1
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: MagneticFieldAccuracy, rhs: MagneticFieldAccuracy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Minimum accuracy accepted for calibration and for placing markers.
    static let minimumAcceptable: MagneticFieldAccuracy = .medium

    var isAcceptable: Bool { self >= Self.minimumAcceptable }

    var displayName: String {
        switch self {
        case .uncalibrated: return "Uncalibrated"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Plain-language recovery instruction shown when accuracy is insufficient.
    var recoveryInstruction: String? {
        switch self {
        case .high, .medium:
            return nil
        case .low, .uncalibrated:
            return "Move the phone slowly in a figure-eight away from metal until accuracy improves."
        }
    }
}

/// How vigorously the device was being moved when a reading was taken.
///
/// Used to refuse a baseline calibration that was collected while the phone was
/// being waved around, and to explain to the user why it was refused.
struct MotionEnergy: Codable, Sendable, Hashable {
    /// Magnitude of user acceleration, in g (gravity excluded by Core Motion).
    var userAcceleration: Double
    /// Magnitude of the rotation rate, radians per second.
    var rotationRate: Double

    /// Above this the phone is not "held steady" in any useful sense.
    static let steadyAccelerationLimit = 0.06
    static let steadyRotationLimit = 0.35

    var isSteady: Bool {
        userAcceleration <= Self.steadyAccelerationLimit
            && rotationRate <= Self.steadyRotationLimit
    }

    static let still = MotionEnergy(userAcceleration: 0, rotationRate: 0)
}

/// One magnetic-field reading.
///
/// * Units are microteslas throughout.
/// * `timestamp` is on the shared monotonic basis (`MonotonicClock`), captured
///   when the Core Motion callback fired -- not a Core Motion epoch.
/// * `interval` is the *measured* gap since the previous delivered sample, not
///   the interval that was requested.
struct MagneticFieldSample: Codable, Sendable, Hashable {
    var timestamp: TimeInterval
    var x: Double
    var y: Double
    var z: Double
    var accuracy: MagneticFieldAccuracy
    var interval: TimeInterval
    var source: MagneticFieldSource
    /// How much the device was being moved and rotated when the reading was
    /// taken. Available whenever the reading came from device motion; `nil` for
    /// the raw-magnetometer fallback, which reports no attitude.
    var motion: MotionEnergy?

    init(
        timestamp: TimeInterval,
        x: Double,
        y: Double,
        z: Double,
        accuracy: MagneticFieldAccuracy,
        interval: TimeInterval,
        source: MagneticFieldSource,
        motion: MotionEnergy? = nil
    ) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.z = z
        self.accuracy = accuracy
        self.interval = interval
        self.source = source
        self.motion = motion
    }

    /// Vector magnitude in µT.
    ///
    /// Magnitude, not a single axis, drives detection: rotating the phone
    /// redistributes the field between axes but leaves the magnitude of a static
    /// field unchanged, so ordinary hand rotation produces far fewer spurious
    /// candidates.
    var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    /// Whether the reading is usable at all (finite and from a usable source).
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && timestamp.isFinite
    }
}

/// Whether the magnetic-field hardware and Core Motion services are usable.
struct MagneticFieldAvailability: Sendable, Equatable {
    var isDeviceMotionAvailable: Bool
    var isMagnetometerAvailable: Bool
    var isAttitudeReferenceFrameAvailable: Bool
    var activeSource: MagneticFieldSource?
    var failureDescription: String?

    /// Calibrated device-motion field data is available, which is the only
    /// configuration in which markers may be placed.
    var supportsCalibratedField: Bool {
        isDeviceMotionAvailable && isAttitudeReferenceFrameAvailable
    }

    /// Nothing magnetic is readable at all.
    var isUnavailable: Bool {
        !isDeviceMotionAvailable && !isMagnetometerAvailable
    }

    static let unavailable = MagneticFieldAvailability(
        isDeviceMotionAvailable: false,
        isMagnetometerAvailable: false,
        isAttitudeReferenceFrameAvailable: false,
        activeSource: nil,
        failureDescription: "This device does not report magnetic-field data."
    )
}

/// Health of the delivered sample stream, recomputed continuously.
struct SampleTimingHealth: Sendable, Equatable, Codable {
    /// Measured samples per second over the recent window.
    var measuredRate: Double
    /// Mean delivered interval, seconds.
    var meanInterval: TimeInterval
    /// Largest gap observed in the recent window, seconds.
    var maximumGap: TimeInterval
    /// Number of samples the measurement is based on.
    var sampleCount: Int

    /// Timing is healthy when the stream is close to the requested rate and free
    /// of long stalls. A stalled stream must not be allowed to place markers.
    var isHealthy: Bool {
        sampleCount >= 10 && measuredRate >= 20 && maximumGap <= 0.15
    }

    static let unknown = SampleTimingHealth(
        measuredRate: 0, meanInterval: 0, maximumGap: 0, sampleCount: 0
    )
}

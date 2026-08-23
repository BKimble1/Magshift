import Foundation
import simd

/// Where the crosshair ray met the locked wall.
struct WallHit: Equatable {
    /// Intersection in world space.
    var worldPosition: SIMD3<Float>
    /// Same point expressed in the locked plane anchor's local space, so a
    /// rendered marker stays glued to the anchor as ARKit refines it.
    var anchorLocalPosition: SIMD3<Float>
    /// Same point in the wall's fixed 2D frame.
    var wallPoint: WallPoint
    /// Distance from the camera to the intersection, metres.
    var distanceFromCamera: Double
    var quality: RaycastQuality
    /// How far outside the detected plane geometry the hit landed, metres.
    /// Zero for a `planeGeometry` hit.
    var extrapolationDistance: Double
}

/// One entry in the pose ring buffer: everything spatial that was true at one
/// instant, stamped on the shared monotonic clock.
///
/// These are recorded from the render loop, independently of the sensor stream.
/// Matching the two is the job of `SpatialSampleBuffer.match(timestamp:tolerance:)`.
struct SpatialSample: Equatable {
    /// Monotonic timestamp captured when the frame callback fired.
    var timestamp: TimeInterval
    /// Camera pose in world space.
    var cameraTransform: simd_float4x4
    /// The locked plane anchor's world transform at this instant.
    var wallTransform: simd_float4x4
    /// The crosshair intersection, if there was a credible one.
    var hit: WallHit?
    var tracking: TrackingQuality
    /// Camera speed, m/s, estimated from consecutive poses.
    var cameraSpeed: Double

    var cameraPosition: SIMD3<Float> { cameraTransform.translation }
}

/// A spatial sample matched to a sensor timestamp, with the error that match cost.
struct SpatialMatch: Equatable {
    var sample: SpatialSample
    /// `abs(sensorTimestamp - poseTimestamp)`, seconds.
    var timingError: TimeInterval
}

/// Bounded ring buffer of recent poses, and the nearest-in-time matcher.
///
/// # Why explicit matching
///
/// Core Motion and ARKit deliver on independent callbacks at different rates.
/// Taking "whatever pose is current when the sensor callback happens to run"
/// silently attributes a reading to wherever the phone drifted to in the
/// meantime. Instead every pose is stamped and buffered, and each anomaly
/// candidate is matched to the nearest pose within a strict tolerance
/// (`DetectorConfiguration.timestampTolerance`, initially 100 ms). If nothing is
/// close enough the reading is still shown live but is never anchored, and the
/// timing error that *was* achieved is stored with every accepted measurement so
/// the tolerance can be revisited with real data.
struct SpatialSampleBuffer {
    private var buffer: BoundedBuffer<SpatialSample>

    /// Three seconds at 60 Hz. Far more than the 100 ms matching tolerance
    /// needs, and still a hard bound.
    static let defaultCapacity = 180

    init(capacity: Int = SpatialSampleBuffer.defaultCapacity) {
        buffer = BoundedBuffer(capacity: capacity)
    }

    var count: Int { buffer.count }
    var isEmpty: Bool { buffer.isEmpty }
    var newest: SpatialSample? { buffer.last }
    var samples: [SpatialSample] { buffer.elements }

    mutating func append(_ sample: SpatialSample) {
        buffer.append(sample)
    }

    mutating func removeAll() {
        buffer.removeAll()
    }

    /// Nearest recorded pose to `timestamp`, or `nil` when none is within
    /// `tolerance`.
    ///
    /// Poses are appended in time order, so the search walks backwards from the
    /// newest and stops as soon as the error starts growing again.
    func match(timestamp: TimeInterval, tolerance: TimeInterval) -> SpatialMatch? {
        guard tolerance >= 0 else { return nil }
        var best: SpatialMatch?
        for sample in buffer.elements.reversed() {
            let error = abs(sample.timestamp - timestamp)
            if let current = best, error > current.timingError {
                // Walking further back can only increase the error.
                break
            }
            best = SpatialMatch(sample: sample, timingError: error)
        }
        guard let best, best.timingError <= tolerance else { return nil }
        return best
    }
}

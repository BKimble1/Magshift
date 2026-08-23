import Foundation
import simd
@testable import WallField

/// A magnetic-field source the test drives sample by sample.
@MainActor
final class ControllableFieldService: MagneticFieldProviding {
    private var continuation: AsyncStream<MagneticFieldSample>.Continuation?
    private var tracker = SampleRateTracker()

    private(set) var isRunning = false
    private(set) var requestedSampleRate: Double = 50
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var availability = Fixture.availableSensor
    var timingHealth: SampleTimingHealth { tracker.health }

    func start(preferredSampleRate: Double) -> AsyncStream<MagneticFieldSample> {
        stop()
        startCount += 1
        requestedSampleRate = preferredSampleRate
        tracker.reset()
        let (stream, continuation) = AsyncStream<MagneticFieldSample>.makeStream()
        self.continuation = continuation
        isRunning = true
        return stream
    }

    func stop() {
        guard isRunning || continuation != nil else { return }
        stopCount += 1
        isRunning = false
        continuation?.finish()
        continuation = nil
    }

    func emit(_ sample: MagneticFieldSample) {
        tracker.record(timestamp: sample.timestamp, reportedInterval: sample.interval)
        continuation?.yield(sample)
    }

    func emit(_ samples: [MagneticFieldSample]) {
        for sample in samples { emit(sample) }
    }
}

/// An `ARSpatialProviding` whose every answer the test sets directly.
@MainActor
final class FakeSpatialProvider: ARSpatialProviding {
    var trackingQuality: TrackingQuality = .normal
    var detectedWalls: [DetectedWall] = [
        DetectedWall(
            id: FakeSpatialProvider.wallID,
            transform: Fixture.anchorTransform,
            center: .zero,
            extentX: 2,
            extentZ: 2,
            boundary: []
        ),
    ]
    var lockedWall: LockedWall?
    var currentHit: WallHit?
    var targetedWallID: UUID? = FakeSpatialProvider.wallID
    var isRunning = false
    var problem: ARSessionProblem?
    var isWallOverlayVisible = true
    var newestSpatialSample: SpatialSample?

    /// Where the crosshair is. Every match the fake returns lands here.
    var crosshair = WallPoint(x: 0, y: 0)
    var cameraSpeed: Double = 0.1
    var timingError: TimeInterval = 0.004
    /// When false, `spatialMatch` returns nil, as it would with no pose close
    /// enough in time.
    var hasPose = true

    private(set) var renderedClusterIDs: [UUID] = []
    private(set) var removedClusterIDs: [UUID] = []
    private(set) var clearedMarkerCount = 0
    private(set) var stopCount = 0

    static let wallID = UUID()

    func start() {
        isRunning = true
        newestSpatialSample = sample(at: Fixture.baseTimestamp)
    }

    func pause() { isRunning = false }
    func resume() { isRunning = true }
    func resetTracking() { lockedWall = nil }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func lockWall(id: UUID) -> Bool {
        guard let wall = detectedWalls.first(where: { $0.id == id }) else { return false }
        lockedWall = LockedWall(
            id: wall.id,
            frame: Fixture.wallFrame,
            anchorTransform: wall.transform,
            extentX: wall.extentX,
            extentZ: wall.extentZ,
            normalSign: 1
        )
        return true
    }

    func unlockWall() { lockedWall = nil }

    func spatialMatch(for timestamp: TimeInterval, tolerance: TimeInterval) -> SpatialMatch? {
        guard hasPose else { return nil }
        return SpatialMatch(sample: sample(at: timestamp), timingError: timingError)
    }

    func renderCluster(_ cluster: AnomalyCluster) { renderedClusterIDs.append(cluster.id) }
    func removeClusterMarker(id: UUID) { removedClusterIDs.append(id) }
    func removeAllClusterMarkers() { clearedMarkerCount += 1 }

    /// Advances the fake's notion of "now", which the coordinator reads for
    /// tracking statistics and live obstruction.
    func advance(to timestamp: TimeInterval) {
        newestSpatialSample = sample(at: timestamp)
        currentHit = newestSpatialSample?.hit
    }

    private func sample(at timestamp: TimeInterval) -> SpatialSample {
        SpatialSample(
            timestamp: timestamp,
            cameraTransform: matrix_identity_float4x4,
            wallTransform: Fixture.anchorTransform,
            hit: Fixture.hit(at: crosshair),
            tracking: trackingQuality,
            cameraSpeed: cameraSpeed
        )
    }
}

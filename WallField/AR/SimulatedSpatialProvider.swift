import Foundation
import Observation
import simd

/// `ARSpatialProviding` backed by `SimulatedEnvironment`.
///
/// Exists so the entire scan flow -- wall selection, locking, calibration,
/// timestamp matching, quality gating, clustering, repeat-pass confidence,
/// review, persistence and export -- runs its real code on the Simulator and in
/// UI tests, where ARKit does not exist.
///
/// It reports plausible values, never impossible ones: tracking degrades when the
/// crosshair leaves the synthetic wall, the raycast genuinely misses off the
/// wall, and speed comes from actual crosshair motion. A Release build can never
/// reach it: only `AppEnvironment` constructs one, and only when
/// `RuntimeMode.current` is `.simulated`, which `#if !DEBUG` makes impossible.
@MainActor
@Observable
final class SimulatedSpatialProvider: ARSpatialProviding {

    /// Stable identity for the synthetic wall across a whole run.
    static let wallID = UUID(uuidString: "5741CE00-0000-4000-8000-000000000001")
        ?? UUID()

    private let environment: SimulatedEnvironment
    private let clock: any MonotonicClock
    private var spatialBuffer = SpatialSampleBuffer()
    private var tickToken: UUID?
    private var previousCrosshair: WallPoint?
    private var previousTimestamp: TimeInterval?

    private(set) var trackingQuality: TrackingQuality = .notAvailable
    private(set) var detectedWalls: [DetectedWall] = []
    private(set) var lockedWall: LockedWall?
    private(set) var currentHit: WallHit?
    private(set) var targetedWallID: UUID?
    private(set) var isRunning = false
    private(set) var problem: ARSessionProblem?
    private(set) var newestSpatialSample: SpatialSample?
    var isWallOverlayVisible = true

    /// Half-extents of the synthetic wall, metres.
    static let halfWidth = SimulatedEnvironment.wallWidth / 2
    static let halfHeight = SimulatedEnvironment.wallHeight / 2

    /// The synthetic plane anchor's transform.
    ///
    /// Built to match the convention of a real vertical `ARPlaneAnchor`: local +Y
    /// is the plane normal, and the plane lies in local XZ.
    static let anchorTransform: simd_float4x4 = {
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(1, 0, 0, 0)   // local X -> world right
        transform.columns.1 = SIMD4<Float>(0, 0, 1, 0)   // local Y -> world +Z (normal)
        transform.columns.2 = SIMD4<Float>(0, -1, 0, 0)  // local Z -> world down
        transform.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        return transform
    }()

    init(environment: SimulatedEnvironment, clock: any MonotonicClock = SystemMonotonicClock()) {
        self.environment = environment
        self.clock = clock
    }

    // MARK: - Lifecycle

    func start() {
        guard tickToken == nil else { return }
        problem = nil
        environment.start()
        detectedWalls = [
            DetectedWall(
                id: Self.wallID,
                transform: Self.anchorTransform,
                center: .zero,
                extentX: Float(SimulatedEnvironment.wallWidth),
                extentZ: Float(SimulatedEnvironment.wallHeight),
                boundary: []
            ),
        ]
        trackingQuality = .normal
        isRunning = true
        tickToken = environment.addTickObserver { [weak self] now in
            self?.recordSample(at: now)
        }
    }

    func pause() {
        isRunning = false
        environment.stop()
    }

    func resume() {
        guard !isRunning else { return }
        environment.start()
        isRunning = true
    }

    func resetTracking() {
        unlockWall()
        spatialBuffer.removeAll()
        newestSpatialSample = nil
        previousCrosshair = nil
        previousTimestamp = nil
        environment.reset()
        problem = nil
    }

    /// Stops sampling and returns the provider to its pre-`start` state, so a
    /// second `start` on the same instance behaves like the first. Mirrors
    /// `ARSessionController.stop()`.
    func stop() {
        if let tickToken { environment.removeTickObserver(tickToken) }
        tickToken = nil
        environment.stop()
        isRunning = false
        unlockWall()
        detectedWalls.removeAll()
        targetedWallID = nil
        trackingQuality = .notAvailable
        spatialBuffer.removeAll()
        newestSpatialSample = nil
        previousCrosshair = nil
        previousTimestamp = nil
    }

    // MARK: - Locking

    func lockWall(id: UUID) -> Bool {
        guard let wall = detectedWalls.first(where: { $0.id == id }) else { return false }
        guard let frame = WallFrame.make(
            anchorTransform: wall.transform,
            cameraPosition: SIMD3<Float>(0, 0, Float(SimulatedEnvironment.cameraDistance))
        ) else { return false }
        lockedWall = LockedWall(
            id: wall.id,
            frame: frame,
            anchorTransform: wall.transform,
            extentX: wall.extentX,
            extentZ: wall.extentZ,
            normalSign: 1
        )
        return true
    }

    func unlockWall() {
        lockedWall = nil
        currentHit = nil
    }

    func spatialMatch(for timestamp: TimeInterval, tolerance: TimeInterval) -> SpatialMatch? {
        spatialBuffer.match(timestamp: timestamp, tolerance: tolerance)
    }

    // MARK: - Rendering

    // Simulated scans draw their markers with SwiftUI on `SimulatedWallCanvas`,
    // so there is no RealityKit scene to update here.
    func renderCluster(_ cluster: AnomalyCluster) {}
    func removeClusterMarker(id: UUID) {}
    func removeAllClusterMarkers() {}

    // MARK: - Sampling

    private func recordSample(at now: TimeInterval) {
        let crosshair = environment.crosshair
        let onWall = environment.isOnWall
            && abs(crosshair.x) <= Self.halfWidth
            && abs(crosshair.y) <= Self.halfHeight

        var speed = environment.speed
        if let previousCrosshair, let previousTimestamp, now > previousTimestamp {
            speed = previousCrosshair.distance(to: crosshair) / (now - previousTimestamp)
        }
        previousCrosshair = crosshair
        previousTimestamp = now

        trackingQuality = onWall ? .normal : .limited(.insufficientFeatures)
        targetedWallID = onWall ? Self.wallID : nil

        let hit: WallHit?
        if let wall = lockedWall, onWall {
            let world = wall.frame.worldPosition(forWallPoint: crosshair)
            hit = WallHit(
                worldPosition: world,
                anchorLocalPosition: SIMD3<Float>(Float(crosshair.x), 0, Float(-crosshair.y)),
                wallPoint: crosshair,
                distanceFromCamera: SimulatedEnvironment.cameraDistance,
                quality: .planeGeometry,
                extrapolationDistance: 0
            )
        } else {
            hit = nil
        }
        currentHit = hit

        let sample = SpatialSample(
            timestamp: now,
            cameraTransform: environment.cameraTransform,
            wallTransform: lockedWall?.anchorTransform ?? Self.anchorTransform,
            hit: hit,
            tracking: trackingQuality,
            cameraSpeed: speed
        )
        spatialBuffer.append(sample)
        newestSpatialSample = sample
    }
}

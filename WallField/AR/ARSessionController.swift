import ARKit
import Combine
import Foundation
import Observation
import RealityKit
import UIKit
import simd

/// Owns the ARKit session and the RealityKit scene for a scan.
///
/// # Why session control lives outside the SwiftUI view
///
/// `ARViewContainer` is a thin `UIViewRepresentable` that does nothing but hand
/// this controller's `ARView` to SwiftUI. All lifecycle -- run, pause, resume,
/// reset, teardown -- lives here, so it survives view identity changes, can be
/// driven by the scan state machine, and can be substituted wholesale by
/// `SimulatedSpatialProvider` for the Simulator and UI tests.
///
/// # Rendering budget
///
/// Entities are created once and then updated in place; nothing is rebuilt per
/// frame. Expensive render features are switched off, LiDAR scene depth is left
/// disabled by default because it costs power for no benefit to this app, and
/// the number of marker entities is bounded by
/// `DetectorConfiguration.maximumClusters`.
@MainActor
@Observable
final class ARSessionController: ARSpatialProviding {

    // MARK: - Observable state

    private(set) var trackingQuality: TrackingQuality = .notAvailable
    private(set) var detectedWalls: [DetectedWall] = []
    private(set) var lockedWall: LockedWall?
    private(set) var currentHit: WallHit?
    private(set) var targetedWallID: UUID?
    private(set) var isRunning = false
    private(set) var problem: ARSessionProblem?
    private(set) var newestSpatialSample: SpatialSample?

    // Computed over a tracked stored property rather than using `didSet`, which
    // `@Observable` does not support on a tracked property.
    private var storedWallOverlayVisible = true
    var isWallOverlayVisible: Bool {
        get { storedWallOverlayVisible }
        set {
            storedWallOverlayVisible = newValue
            applyOverlayVisibility()
        }
    }

    // MARK: - AR objects

    /// Not observable: the AR view is a rendering surface, not state a view
    /// should redraw for, and building it lazily would otherwise count as a
    /// mutation during a SwiftUI update.
    @ObservationIgnored private var storedARView: ARView?

    /// The view handed to SwiftUI.
    ///
    /// Built on first use rather than in `init`. Constructing an `ARView` starts
    /// RealityKit's renderer and creates an `ARSession`, which is real work on a
    /// real device -- and on the Simulator there is no AR at all, so it is work
    /// that has never run outside a device. Doing it in `init` meant the moment a
    /// screen that *might* use AR appeared was the moment the whole AR stack came
    /// up: while the user was still reading the preparation checklist, or on the
    /// diagnostics screen where the AR toggle may never be switched on. Now
    /// nothing is built until something actually asks for the view or starts a
    /// session, which is what the rest of this app already promised.
    var arView: ARView {
        if let storedARView { return storedARView }
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        configureRenderOptions(on: view)
        storedARView = view
        return view
    }

    private let configuration: DetectorConfiguration
    private let clock: any MonotonicClock
    private var relay: ARSessionEventRelay?
    private var eventTask: Task<Void, Never>?
    private var updateSubscription: (any Cancellable)?

    private var spatialBuffer = SpatialSampleBuffer()
    private var wallAnchors: [UUID: AnchorEntity] = [:]
    private var wallModels: [UUID: ModelEntity] = [:]
    private var wallMeshSignatures: [UUID: Int] = [:]
    private var markerEntities: [UUID: Entity] = [:]
    private var markerRoot: Entity?

    private var previousSampleTime: TimeInterval?
    private var previousCameraPosition: SIMD3<Float>?
    private var smoothedSpeed: Double = 0
    private var sampleLimiter = RateLimiter(hz: 60)

    // MARK: - Init

    init(
        configuration: DetectorConfiguration = .default,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) {
        self.configuration = configuration.sanitized()
        self.clock = clock
    }

    private func configureRenderOptions(on view: ARView) {
        // Restrained rendering: none of these effects help read a heat map, and
        // all of them cost power and generate heat during a long scan.
        view.renderOptions = [
            .disableMotionBlur,
            .disableDepthOfField,
            .disableHDR,
            .disableCameraGrain,
            .disableGroundingShadows,
        ]
        view.debugOptions = []
    }

    // MARK: - Lifecycle

    /// The reason a session must not be started, or `nil` if it may be.
    ///
    /// Read live rather than from the capabilities captured at launch: camera
    /// access can be granted, or revoked, while the app is running.
    private static func blockingProblem() -> ARSessionProblem? {
        guard ARWorldTrackingConfiguration.isSupported else {
            Log.ar.error("ARWorldTrackingConfiguration is not supported on this device.")
            return .unsupportedDevice
        }
        switch DeviceCapabilities.readCameraAuthorization() {
        case .denied: return .cameraAccessDenied
        case .restricted: return .cameraAccessRestricted
        case .authorized, .notDetermined: return nil
        }
    }

    func start() {
        if let blocker = Self.blockingProblem() {
            problem = blocker
            return
        }

        problem = nil
        attachDelegateIfNeeded()
        subscribeToSceneUpdatesIfNeeded()
        runSession(options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        Log.ar.debug("AR session started.")
    }

    func pause() {
        guard isRunning, let storedARView else { return }
        storedARView.session.pause()
        isRunning = false
        Log.ar.debug("AR session paused.")
    }

    func resume() {
        guard !isRunning, problem == nil || problem?.isRecoverable == true else { return }
        // The same guards as `start`. `resume` is reachable from the blocked
        // screen's Try again button, so it cannot assume a session ever ran, nor
        // that the reason it stopped has gone away.
        if let blocker = Self.blockingProblem() {
            problem = blocker
            return
        }

        problem = nil
        attachDelegateIfNeeded()
        subscribeToSceneUpdatesIfNeeded()
        // Resuming keeps existing anchors so a locked wall survives a short
        // interruption. A failure to relocalise is reported, never papered over.
        runSession(options: [])
        isRunning = true
        Log.ar.debug("AR session resumed.")
    }

    func resetTracking() {
        unlockWall()
        removeAllClusterMarkers()
        detectedWalls.removeAll()
        clearWallOverlays()
        spatialBuffer.removeAll()
        newestSpatialSample = nil
        previousCameraPosition = nil
        previousSampleTime = nil
        smoothedSpeed = 0
        problem = nil
        runSession(options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        // Deliberately `storedARView`, not `arView`: stopping something that was
        // never started must not be the thing that builds an AR view.
        storedARView?.session.pause()
        storedARView?.session.delegate = nil
        eventTask?.cancel()
        eventTask = nil
        updateSubscription?.cancel()
        updateSubscription = nil
        relay = nil
        isRunning = false
        removeAllClusterMarkers()
        clearWallOverlays()
        spatialBuffer.removeAll()
        newestSpatialSample = nil
        targetedWallID = nil
        Log.ar.debug("AR session stopped.")
    }

    private func runSession(options: ARSession.RunOptions) {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical]
        config.worldAlignment = .gravity
        config.isLightEstimationEnabled = false
        config.environmentTexturing = .none
        // Scene depth is deliberately left off. It is an optional quality
        // enhancement on LiDAR devices only, and the primary experience must be
        // identical on iPhones without LiDAR. Enabling it would cost power for a
        // benefit this app does not currently use.
        arView.session.run(config, options: options)
    }

    private func attachDelegateIfNeeded() {
        guard relay == nil else { return }
        let (stream, continuation) = AsyncStream<ARSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        let relay = ARSessionEventRelay(continuation: continuation)
        self.relay = relay
        arView.session.delegate = relay
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    private func subscribeToSceneUpdatesIfNeeded() {
        guard updateSubscription == nil else { return }
        // RealityKit delivers `SceneEvents.Update` on the main thread once per
        // rendered frame. `assumeIsolated` states that fact to the compiler
        // rather than hopping through a task, which would decouple pose sampling
        // from the frame it belongs to and add avoidable timing error.
        //
        // It states it as a *fact*, though, and `assumeIsolated` traps when the
        // fact does not hold -- which would take the whole app down mid-scan on
        // the strength of an undocumented threading guarantee. The thread is
        // therefore checked first, and a callback arriving anywhere else drops
        // one pose sample instead. At 60 Hz against a 100 ms matching tolerance,
        // a dropped sample costs nothing measurable.
        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            guard Thread.isMainThread else {
                Log.ar.error("Scene update arrived off the main thread; pose sample dropped.")
                return
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                HardwarePhaseRecorder.during(.samplingCameraPose) { self.sampleFrame() }
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: ARSessionEvent) {
        switch event {
        case .wallsChanged(let walls):
            for wall in walls {
                if let index = detectedWalls.firstIndex(where: { $0.id == wall.id }) {
                    detectedWalls[index] = wall
                } else {
                    detectedWalls.append(wall)
                }
                HardwarePhaseRecorder.during(.buildingWallOverlay) {
                    updateWallOverlay(for: wall)
                }
            }

        case .wallsRemoved(let identifiers):
            detectedWalls.removeAll { identifiers.contains($0.id) }
            for identifier in identifiers {
                removeWallOverlay(id: identifier)
                if lockedWall?.id == identifier {
                    // The wall the scan was locked to is gone. Nothing can be
                    // placed any more, and existing markers cannot be trusted to
                    // be where they appear.
                    Log.ar.notice("Locked plane anchor was removed by ARKit.")
                    problem = .relocalizationFailed
                }
            }

        case .trackingChanged(let quality):
            if trackingQuality != quality { trackingQuality = quality }

        case .failed(let message):
            problem = .sessionFailed(message)
            isRunning = false

        case .interrupted:
            problem = .interrupted
            isRunning = false

        case .interruptionEnded:
            if problem == .interrupted { problem = nil }

        case .relocalizationDeclined:
            // Relocalisation is always refused (see the delegate method), but
            // refusing it only *costs* something when there was a locked wall
            // whose coordinates the markers depend on. With nothing locked there
            // is nothing to invalidate, so tracking restarts from scratch and the
            // user carries on mapping instead of being sent back to Home.
            if lockedWall == nil {
                Log.ar.notice("Relocalisation declined with no wall locked; restarting tracking.")
                resetTracking()
            } else {
                problem = .relocalizationFailed
            }
        }
    }

    // MARK: - Per-frame sampling

    private func sampleFrame() {
        let now = clock.now
        guard sampleLimiter.allow(at: now) else { return }
        guard let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let quality = TrackingQuality(frame.camera.trackingState)
        // Assigned only on change. `@Observable` invalidates observers on every
        // write regardless of equality, and this runs once per rendered frame.
        if trackingQuality != quality { trackingQuality = quality }

        let cameraPosition = cameraTransform.translation
        if let previousPosition = previousCameraPosition,
           let previousTime = previousSampleTime,
           now > previousTime {
            let instantaneous = Double(simd_distance(cameraPosition, previousPosition)) / (now - previousTime)
            // Light exponential smoothing: raw frame-to-frame speed is dominated
            // by tracking jitter, which would trip the speed gate constantly.
            smoothedSpeed = smoothedSpeed * 0.7 + instantaneous * 0.3
        }
        previousCameraPosition = cameraPosition
        previousSampleTime = now

        let hit: WallHit?
        let targeted: UUID?
        if let wall = lockedWall {
            hit = performRaycast(for: wall, cameraPosition: cameraPosition)
            targeted = wall.id
        } else {
            hit = nil
            targeted = raycastAnyVerticalPlane()
        }
        currentHit = hit
        if targetedWallID != targeted { targetedWallID = targeted }

        let sample = SpatialSample(
            timestamp: now,
            cameraTransform: cameraTransform,
            wallTransform: lockedWall?.anchorTransform ?? matrix_identity_float4x4,
            hit: hit,
            tracking: quality,
            cameraSpeed: smoothedSpeed
        )
        spatialBuffer.append(sample)
        newestSpatialSample = sample
    }

    /// Raycasts from the centre of the screen onto the locked wall.
    ///
    /// Two attempts, in order:
    ///
    /// 1. `.existingPlaneGeometry` -- the ray must hit the plane's actual
    ///    detected shape. Full spatial quality.
    /// 2. `.existingPlaneInfinite`, **restricted to the locked anchor**, and only
    ///    accepted within `maximumExtrapolationDistance` of the mapped extent.
    ///    Marked `.extrapolatedPlane` so the reduced quality travels with the
    ///    measurement.
    ///
    /// Anything else yields no hit at all. There is no third fallback onto
    /// feature points or estimated planes, because a marker placed on a guess is
    /// worse than no marker.
    private func performRaycast(for wall: LockedWall, cameraPosition: SIMD3<Float>) -> WallHit? {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard center.x > 0, center.y > 0 else { return nil }

        if let result = arView
            .raycast(from: center, allowing: .existingPlaneGeometry, alignment: .vertical)
            .first(where: { $0.anchor?.identifier == wall.id }) {
            return makeHit(
                result: result, wall: wall, cameraPosition: cameraPosition,
                quality: .planeGeometry, extrapolation: 0
            )
        }

        guard let result = arView
            .raycast(from: center, allowing: .existingPlaneInfinite, alignment: .vertical)
            .first(where: { $0.anchor?.identifier == wall.id })
        else { return nil }

        let anchorTransform = result.anchor?.transform ?? wall.anchorTransform
        let local = anchorLocal(worldPosition: result.worldTransform.translation, anchorTransform: anchorTransform)
        let extrapolation = extrapolationDistance(localPosition: local, wallID: wall.id)
        guard extrapolation <= configuration.maximumExtrapolationDistance else { return nil }
        return makeHit(
            result: result, wall: wall, cameraPosition: cameraPosition,
            quality: .extrapolatedPlane, extrapolation: extrapolation
        )
    }

    /// Which detected vertical plane the crosshair is on, before anything is
    /// locked. Only planes big enough to scan are offered.
    private func raycastAnyVerticalPlane() -> UUID? {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard center.x > 0, center.y > 0 else { return nil }
        let results = arView.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .vertical)
        for result in results {
            guard let identifier = result.anchor?.identifier else { continue }
            if let wall = detectedWalls.first(where: { $0.id == identifier }), wall.isUsableAsWall {
                return identifier
            }
        }
        return nil
    }

    private func makeHit(
        result: ARRaycastResult,
        wall: LockedWall,
        cameraPosition: SIMD3<Float>,
        quality: RaycastQuality,
        extrapolation: Double
    ) -> WallHit {
        let worldPosition = result.worldTransform.translation
        let anchorTransform = result.anchor?.transform ?? wall.anchorTransform
        return WallHit(
            worldPosition: worldPosition,
            anchorLocalPosition: anchorLocal(worldPosition: worldPosition, anchorTransform: anchorTransform),
            wallPoint: wall.frame.wallPoint(forWorldPosition: worldPosition),
            distanceFromCamera: Double(simd_distance(cameraPosition, worldPosition)),
            quality: quality,
            extrapolationDistance: extrapolation
        )
    }

    private func anchorLocal(worldPosition: SIMD3<Float>, anchorTransform: simd_float4x4) -> SIMD3<Float> {
        let local = simd_inverse(anchorTransform) * SIMD4<Float>(worldPosition, 1)
        return SIMD3<Float>(local.x, local.y, local.z)
    }

    /// How far outside the plane's mapped rectangle a local point lies, metres.
    private func extrapolationDistance(localPosition: SIMD3<Float>, wallID: UUID) -> Double {
        guard let wall = detectedWalls.first(where: { $0.id == wallID }) else { return .infinity }
        let dx = max(0, abs(localPosition.x - wall.center.x) - wall.extentX / 2)
        let dz = max(0, abs(localPosition.z - wall.center.z) - wall.extentZ / 2)
        return Double((dx * dx + dz * dz).squareRoot())
    }

    // MARK: - Locking

    func lockWall(id: UUID) -> Bool {
        guard let wall = detectedWalls.first(where: { $0.id == id }) else { return false }
        let cameraPosition = arView.session.currentFrame?.camera.transform.translation
        guard let frame = WallFrame.make(anchorTransform: wall.transform, cameraPosition: cameraPosition) else {
            Log.ar.notice("Refused to lock a plane whose orientation is not usable as a wall.")
            return false
        }
        let anchorNormal = simd_normalize(wall.transform.yAxis)
        let sign: Float = simd_dot(anchorNormal, frame.normal.simd) >= 0 ? 1 : -1

        lockedWall = LockedWall(
            id: wall.id,
            frame: frame,
            anchorTransform: wall.transform,
            extentX: wall.extentX,
            extentZ: wall.extentZ,
            normalSign: sign
        )
        installMarkerRoot(on: wall.id)
        applyOverlayVisibility()
        Log.ar.debug("Wall locked.")
        return true
    }

    func unlockWall() {
        lockedWall = nil
        currentHit = nil
        targetedWallID = nil
        markerRoot?.removeFromParent()
        markerRoot = nil
        markerEntities.removeAll()
        applyOverlayVisibility()
    }

    func spatialMatch(for timestamp: TimeInterval, tolerance: TimeInterval) -> SpatialMatch? {
        spatialBuffer.match(timestamp: timestamp, tolerance: tolerance)
    }

    // MARK: - Wall overlay rendering

    private func updateWallOverlay(for wall: DetectedWall) {
        let anchorEntity: AnchorEntity
        if let existing = wallAnchors[wall.id] {
            anchorEntity = existing
        } else {
            anchorEntity = AnchorEntity(world: wall.transform)
            arView.scene.addAnchor(anchorEntity)
            wallAnchors[wall.id] = anchorEntity
        }
        anchorEntity.transform = Transform(matrix: wall.transform)

        let material = WallVisualStyle.overlayMaterial(isSelected: wall.id == lockedWall?.id)
        let signature = meshSignature(for: wall)

        if let model = wallModels[wall.id] {
            // The entity is updated in place, and its mesh only when the wall's
            // shape actually changed. ARKit refines a plane many times a second,
            // usually by fractions of a millimetre; rebuilding the mesh for each
            // of those uploaded a fresh vertex buffer to the GPU tens of times a
            // second to draw a shape nobody could see change.
            if wallMeshSignatures[wall.id] != signature {
                model.model = ModelComponent(
                    mesh: WallMeshBuilder.mesh(for: wall), materials: [material]
                )
                wallMeshSignatures[wall.id] = signature
            }
        } else {
            let model = ModelEntity(mesh: WallMeshBuilder.mesh(for: wall), materials: [material])
            model.name = "wall-\(wall.id.uuidString)"
            anchorEntity.addChild(model)
            wallModels[wall.id] = model
            wallMeshSignatures[wall.id] = signature
        }
        applyOverlayVisibility()
    }

    /// Identifies the shape a wall's mesh was last built for.
    ///
    /// Quantised to a millimetre: below that the overlay does not visibly change,
    /// and the point of the signature is to not pay for redraws nobody can see.
    private func meshSignature(for wall: DetectedWall) -> Int {
        var hasher = Hasher()
        hasher.combine(wall.boundary.count)
        hasher.combine(Int((wall.extentX * 1000).rounded()))
        hasher.combine(Int((wall.extentZ * 1000).rounded()))
        hasher.combine(Int((wall.center.x * 1000).rounded()))
        hasher.combine(Int((wall.center.z * 1000).rounded()))
        return hasher.finalize()
    }

    private func removeWallOverlay(id: UUID) {
        wallModels[id]?.removeFromParent()
        wallModels[id] = nil
        wallMeshSignatures[id] = nil
        if let anchor = wallAnchors[id] {
            storedARView?.scene.removeAnchor(anchor)
        }
        wallAnchors[id] = nil
    }

    private func clearWallOverlays() {
        for (id, _) in wallAnchors { removeWallOverlay(id: id) }
        wallAnchors.removeAll()
        wallModels.removeAll()
        wallMeshSignatures.removeAll()
    }

    private func applyOverlayVisibility() {
        for (id, model) in wallModels {
            let isSelected = id == lockedWall?.id
            // Once a wall is locked, unselected walls are hidden entirely rather
            // than merely dimmed, so there is no ambiguity about which surface
            // the readings belong to.
            let shouldShow: Bool
            if lockedWall == nil {
                shouldShow = storedWallOverlayVisible
            } else {
                shouldShow = storedWallOverlayVisible && isSelected
            }
            model.isEnabled = shouldShow
            model.model?.materials = [WallVisualStyle.overlayMaterial(isSelected: isSelected)]
        }
    }

    // MARK: - Marker rendering

    private func installMarkerRoot(on wallID: UUID) {
        markerRoot?.removeFromParent()
        markerEntities.removeAll()
        guard let anchor = wallAnchors[wallID] else {
            // The overlay anchor is created from the first `wallsChanged` event,
            // which always precedes locking, so this is defensive only.
            Log.ar.notice("No anchor entity for the locked wall; markers cannot be attached.")
            markerRoot = nil
            return
        }
        let root = Entity()
        root.name = "markers"
        anchor.addChild(root)
        markerRoot = root
    }

    func renderCluster(_ cluster: AnomalyCluster) {
        HardwarePhaseRecorder.during(.placingMarker) { renderClusterBody(cluster) }
    }

    private func renderClusterBody(_ cluster: AnomalyCluster) {
        guard let markerRoot, let wall = lockedWall else { return }
        let entity: Entity
        if let existing = markerEntities[cluster.id] {
            existing.children.removeAll()
            entity = existing
        } else {
            guard markerEntities.count < configuration.maximumClusters else { return }
            let created = Entity()
            created.name = "marker-\(cluster.id.uuidString)"
            markerRoot.addChild(created)
            markerEntities[cluster.id] = created
            entity = created
        }
        MarkerEntityFactory.populate(entity, cluster: cluster, normalSign: wall.normalSign)
        let position = SIMD3<Float>(
            cluster.anchorLocalPosition.x,
            cluster.anchorLocalPosition.y,
            cluster.anchorLocalPosition.z
        )
        // Same rule as the wall mesh: nothing non-finite reaches the renderer.
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            Log.ar.error("Refused to place a marker at a non-finite position.")
            removeClusterMarker(id: cluster.id)
            return
        }
        entity.position = position
    }

    func removeClusterMarker(id: UUID) {
        markerEntities[id]?.removeFromParent()
        markerEntities[id] = nil
    }

    func removeAllClusterMarkers() {
        for entity in markerEntities.values { entity.removeFromParent() }
        markerEntities.removeAll()
    }
}

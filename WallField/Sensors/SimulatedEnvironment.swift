import Foundation
import Observation
import simd

/// Deterministic pseudo-random generator.
///
/// A fixed algorithm with a fixed seed so a simulated scan produces byte-for-byte
/// the same field trace every run. Reproducibility is the whole point: a UI test
/// that sometimes sees an anomaly is worse than no test.
struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64 = 0x5741_4C4C_4649_454C) {
        self.state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Uniform in `0..<1`.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Standard normal via Box-Muller.
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A synthetic wall with hidden magnetic sources, shared by the simulated sensor
/// and the simulated AR provider so the two stay physically consistent.
///
/// This is what makes the Simulator build meaningful rather than decorative:
/// moving the crosshair over a hidden source really does raise the field the
/// sensor reports, so calibration, timestamp matching, quality gating,
/// clustering, repeat-pass confidence, review, persistence and export all run
/// their real code paths with no special cases.
///
/// Unreachable in a Release build: `RuntimeMode.resolve()` cannot return
/// `.simulated` there, and `AppEnvironment` builds one only in that mode.
@MainActor
@Observable
final class SimulatedEnvironment {

    /// A hidden magnetic source on the synthetic wall.
    struct Source: Sendable, Hashable {
        var point: WallPoint
        /// Peak deviation at zero distance, µT. Negative models shielding.
        var amplitude: Double
        /// Spatial spread, metres.
        var spread: Double
    }

    /// Whether the phone is being held still or swept.
    enum MotionState: Sendable {
        case still
        case sweeping
    }

    // MARK: - Fixed synthetic world

    static let wallWidth: Double = 1.4
    static let wallHeight: Double = 1.6
    static let baselineMagnitude: Double = 48.0
    static let noiseSigma: Double = 0.22
    static let sweepSpeed: Double = 0.25
    static let sweepHalfWidth: Double = 0.5
    static let sweepRow: Double = 0.20
    static let cameraDistance: Double = 0.09

    /// The hidden sources. Three sit on the auto-sweep line so an automated run
    /// always encounters them; two sit off it so the 2D summary map has content
    /// that only manual scanning reaches.
    static let sources: [Source] = [
        Source(point: WallPoint(x: -0.35, y: 0.20), amplitude: 17.0, spread: 0.035),
        Source(point: WallPoint(x: 0.08, y: 0.20), amplitude: 9.5, spread: 0.032),
        Source(point: WallPoint(x: 0.42, y: 0.20), amplitude: -8.0, spread: 0.040),
        Source(point: WallPoint(x: -0.10, y: 0.55), amplitude: 12.0, spread: 0.045),
        Source(point: WallPoint(x: 0.25, y: -0.30), amplitude: 6.5, spread: 0.030),
    ]

    /// The synthetic wall's frame, expressed in a synthetic world where the wall
    /// lies in the XY plane at the origin with its normal along +Z.
    static let wallFrame = WallFrame(
        origin: Vector3(x: 0, y: 0, z: 0),
        right: Vector3(x: 1, y: 0, z: 0),
        up: Vector3(x: 0, y: 1, z: 0),
        normal: Vector3(x: 0, y: 0, z: 1)
    )

    // MARK: - Live state

    /// Where the crosshair currently sits on the synthetic wall.
    ///
    /// The type is named rather than written as `Self`: Swift rejects a
    /// covariant `Self` in a stored property's initializer inside a class, even
    /// a final one.
    private(set) var crosshair = WallPoint(
        x: -SimulatedEnvironment.sweepHalfWidth,
        y: SimulatedEnvironment.sweepRow
    )
    private(set) var motionState: MotionState = .still
    /// Current crosshair speed, m/s.
    private(set) var speed: Double = 0
    /// Whether the crosshair drives itself along the sweep line.
    var isAutoSweeping = true
    /// Set false to simulate the crosshair leaving the wall.
    var isOnWall = true

    private var sweepDirection: Double = 1
    private var random = DeterministicRandom()
    private var driftPhase: Double = 0
    private var tickTask: Task<Void, Never>?
    private var lastTick: TimeInterval?
    private var observers: [UUID: @MainActor (TimeInterval) -> Void] = [:]

    private let clock: any MonotonicClock

    init(clock: any MonotonicClock = SystemMonotonicClock()) {
        self.clock = clock
    }

    // MARK: - Lifecycle

    func start() {
        guard tickTask == nil else { return }
        lastTick = nil
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        speed = 0
    }

    func reset() {
        crosshair = WallPoint(x: -Self.sweepHalfWidth, y: Self.sweepRow)
        sweepDirection = 1
        random = DeterministicRandom()
        driftPhase = 0
        speed = 0
        motionState = .still
        isOnWall = true
        lastTick = nil
    }

    /// Hold the phone still, as required during calibration.
    func holdStill() {
        motionState = .still
        speed = 0
    }

    /// Begin sweeping the wall.
    func beginSweeping() {
        motionState = .sweeping
    }

    /// Manual crosshair placement, used when the user drags on the simulated
    /// canvas. Turns auto-sweep off so the two cannot fight.
    func moveCrosshair(to point: WallPoint, elapsed: TimeInterval) {
        isAutoSweeping = false
        let distance = crosshair.distance(to: point)
        crosshair = point
        speed = elapsed > 0 ? distance / elapsed : 0
        motionState = .sweeping
    }

    // MARK: - Observation

    /// Registers a per-tick callback. Returns a token used to unregister.
    @discardableResult
    func addTickObserver(_ observer: @escaping @MainActor (TimeInterval) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeTickObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func tick() {
        let now = clock.now
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let dt = min(max(now - last, 0), 0.1)
        guard dt > 0 else { return }

        driftPhase += dt

        if isAutoSweeping, motionState == .sweeping {
            var x = crosshair.x + sweepDirection * Self.sweepSpeed * dt
            if x > Self.sweepHalfWidth {
                x = Self.sweepHalfWidth
                sweepDirection = -1
            } else if x < -Self.sweepHalfWidth {
                x = -Self.sweepHalfWidth
                sweepDirection = 1
            }
            crosshair = WallPoint(x: x, y: Self.sweepRow)
            speed = Self.sweepSpeed
        } else if motionState == .still {
            speed = 0
        }

        for observer in observers.values {
            observer(now)
        }
    }

    // MARK: - Physics

    /// Field magnitude at the current crosshair, µT.
    ///
    /// Each source contributes a Gaussian bump scaled by an inverse-square-ish
    /// falloff with distance from the wall, plus slow environmental drift and
    /// sensor noise. The point is not to be a physics engine -- it is to produce
    /// a signal with the same shape, scale and noise character as a real one so
    /// the detector is genuinely exercised.
    func sampleMagnitude() -> Double {
        var magnitude = Self.baselineMagnitude
        magnitude += 0.6 * sin(driftPhase / 9.5)

        if isOnWall {
            let falloff = pow(Self.cameraDistance / max(Self.cameraDistance, 0.03), 2)
            for source in Self.sources {
                let distance = crosshair.distance(to: source.point)
                let exponent = -(distance * distance) / (2 * source.spread * source.spread)
                magnitude += source.amplitude * exp(exponent) * falloff
            }
        }

        magnitude += random.gaussian() * Self.noiseSigma
        return magnitude
    }

    /// A field vector whose magnitude equals `magnitude`.
    ///
    /// The direction is fixed rather than modelled, because nothing downstream
    /// uses direction -- detection runs on magnitude precisely so orientation
    /// does not matter.
    func vector(forMagnitude magnitude: Double) -> SIMD3<Double> {
        let direction = SIMD3<Double>(0.3123, 0.5205, 0.7943)
        let length = (direction.x * direction.x
            + direction.y * direction.y
            + direction.z * direction.z).squareRoot()
        return (direction / length) * magnitude
    }

    /// Motion energy for the current state.
    ///
    /// The two states must straddle `MotionEnergy.isSteady`, or the simulation
    /// misrepresents the one thing this value exists to decide: a phone being
    /// swept across a wall must be refused as a calibration baseline, exactly as
    /// it is on a device. The sweeping figures are therefore above both limits
    /// (0.06 g and 0.35 rad/s), which is what a hand-held pass actually
    /// produces; the still figures are comfortably below them.
    var motionEnergy: MotionEnergy {
        switch motionState {
        case .still:
            return MotionEnergy(userAcceleration: 0.004, rotationRate: 0.01)
        case .sweeping:
            return MotionEnergy(userAcceleration: 0.09, rotationRate: 0.45)
        }
    }

    /// Synthetic world position of the crosshair.
    var crosshairWorldPosition: SIMD3<Float> {
        Self.wallFrame.worldPosition(forWallPoint: crosshair)
    }

    /// Synthetic camera pose looking at the crosshair from `cameraDistance`.
    var cameraTransform: simd_float4x4 {
        var transform = matrix_identity_float4x4
        let position = crosshairWorldPosition + SIMD3<Float>(0, 0, Float(Self.cameraDistance))
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return transform
    }
}

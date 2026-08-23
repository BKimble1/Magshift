# Architecture

## Shape

WallField is a single-target SwiftUI app with no third-party dependencies. It is
organised so that everything scientifically interesting is a pure value type that
can be tested without a device, a camera or a session, and everything that
touches hardware is a thin, replaceable adapter behind a protocol.

```text
                     ┌──────────────────────────────┐
                     │        AppEnvironment        │  composition root
                     └──────────────┬───────────────┘
                                    │ injects
   ┌────────────────────────────────┼────────────────────────────────┐
   │                                │                                │
┌──┴───────────────────┐  ┌─────────┴──────────┐  ┌──────────────────┴───┐
│ MagneticFieldProviding│  │  ARSpatialProviding │  │     ScanStoring      │
│  CoreMotion / Sim     │  │  ARKit / Sim        │  │  File / InMemory     │
└──┬───────────────────┘  └─────────┬──────────┘  └──────────────────┬───┘
   │ samples                        │ poses, raycasts                │ records
   └──────────────┬─────────────────┘                                │
                  ▼                                                  │
        ┌───────────────────────┐                                    │
        │    ScanCoordinator    │  @MainActor, sequencing only       │
        └───────────┬───────────┘                                    │
                    │ calls into pure value types                    │
   ┌────────────────┼───────────────┬────────────────┬───────────────┘
   ▼                ▼               ▼                ▼
CalibrationEngine  OnlineAnomaly   ScanQualityGate  ClusterEngine
                   Detector
```

`ScanCoordinator` owns *sequencing and presentation state*: which step the user
is on, what the HUD shows, when hardware starts and stops. It contains no
statistics at all. Calibration, detection, quality gating and clustering are
separate `struct`s with no framework imports, which is what makes them
exhaustively testable with synthetic data.

## Module boundaries

| Protocol | Production | Test / Simulator |
|---|---|---|
| `MagneticFieldProviding` | `CoreMotionMagneticFieldService` | `SimulatedMagneticFieldService`, `ScriptedMagneticFieldService`, `ControllableFieldService` |
| `ARSpatialProviding` | `ARSessionController` | `SimulatedSpatialProvider`, `FakeSpatialProvider` |
| `ScanStoring` | `FileScanStore` (actor) | `InMemoryScanStore` (actor) |
| `AnomalyDetecting` | `OnlineAnomalyDetector` | any value type conforming |
| `MonotonicClock` | `SystemMonotonicClock` | `ManualClock` |

There are no global mutable singletons. `AppEnvironment` is created once by
`WallFieldApp` and injected through the SwiftUI environment; a preview, a UI test
and the shipping app differ only in which `AppEnvironment` they are handed.

## Coordinate systems

Three frames are in play, and confusing them is the classic way an AR
measurement app produces plausible nonsense.

**World space.** ARKit's gravity-aligned right-handed frame, +Y up, metres. All
camera poses and raycast hits arrive here.

**Anchor-local space.** Each `ARPlaneAnchor` has its own frame in which **local
+Y is the plane normal** and the plane lies in local XZ. Rendered markers live
here, parented to the plane's `AnchorEntity`, so they stay glued to the surface
as ARKit refines it. Marker discs are offset a few millimetres along local ±Y
(sign chosen so they face the viewer) to avoid z-fighting with the wall overlay.

**Wall space.** A fixed 2D frame captured *once*, when the user locks the wall
(`WallFrame.make(anchorTransform:cameraPosition:)`):

* `normal` = the plane normal, flipped if necessary to point at the camera;
* `up` = world up projected into the plane, so "up" on the saved map is up on
  the wall;
* `right` = `up × normal`, giving a right-handed basis where `right × up == normal`.

This matters because ARKit's vertical plane anchors carry an **arbitrary rotation
about their normal**, and ARKit re-centres anchors as it refines them. Using raw
anchor-local X/Z as "wall coordinates" would produce a 2D map at a random angle
that shifted during the scan. Capturing the frame once, in world space, keeps
wall coordinates stable for the whole scan.

The trade-off is explicit: a large relocalisation or world-origin change
invalidates the captured frame. WallField does not silently remap old data. The
session delegate returns `false` from `sessionShouldAttemptRelocalization`, and a
lost or removed locked anchor moves the scan to a blocked state that the user has
to resolve.

Every accepted measurement stores its position in **all three**: `wallPoint`
(wall space), `worldPosition` (world space), and the cluster's
`anchorLocalPosition` (anchor space).

## Time basis

Core Motion and ARKit deliver on independent callbacks, at different rates, with
timestamps whose epochs the app must not assume are shared.

The rule: **every callback stamps its own data with
`ProcessInfo.processInfo.systemUptime`, captured inside the callback**, and all
matching happens in that one basis (`MonotonicClock`). `systemUptime` is
monotonic while the device is awake and immune to wall-clock changes.

* Field samples are stamped in the Core Motion handler.
* Pose samples are stamped in the RealityKit scene-update callback, at most 60
  times a second, and appended to a bounded ring buffer of 180 entries — three
  seconds of history for a 100 ms matching tolerance.
* `SpatialSampleBuffer.match(timestamp:tolerance:)` finds the nearest pose to a
  candidate's timestamp, and returns `nil` rather than a stale one if nothing is
  close enough. A reading with no matching pose is shown live but never anchored.
* The achieved timing error is stored with every accepted measurement and
  summarised per scan, so the 100 ms tolerance can be revisited against real data
  rather than defended by assertion.

The delivered *interval* is measured from Core Motion's own higher-resolution
timestamps, which is a better estimate of the sensor's cadence than callback
scheduling. Diagnostics additionally reports the mean observed
`systemUptime − CMDeviceMotion.timestamp`, so the assumption that the two clocks
share an epoch can be **verified on a device** instead of believed.

## Concurrency

Swift 6 with `SWIFT_STRICT_CONCURRENCY = complete`.

**The main actor is the sensing pipeline's home.** Per-sample work is O(1) over
a bounded window at roughly 50 Hz, which is negligible; confining it to the main
actor removes an entire class of race between the Core Motion callback, the AR
callback and SwiftUI state. Work that is *not* O(1) — export generation, which
walks every stored measurement — runs in a detached task.

Framework callbacks that fire off the main actor convert to plain values *before*
crossing:

* `ARSessionEventRelay` is an `ARSessionDelegate` that turns each callback into a
  `Sendable` `ARSessionEvent` and yields it to an `AsyncStream`. No `ARFrame` is
  ever retained (retaining frames stalls ARKit) and no ARKit object crosses to
  another actor.
* The Core Motion handler runs on a dedicated serial `OperationQueue`, reads
  `Double`s out of `CMDeviceMotion`, and yields a value struct.

Three narrow, documented exceptions to automatic checking exist, each justified
at its declaration site: `ARSessionEventRelay` and `IntervalTracker` are
`@unchecked Sendable` (immutable or lock-guarded storage that cannot be an actor
because it is called synchronously from a framework callback), `ManualClock` is
`@unchecked Sendable` for the same reason, `DetectedWall` states its conformance
explicitly rather than depending on whether a given SDK marks `simd_float4x4`
`Sendable`, and `CoreMotionMagneticFieldService.motionManager` is
`nonisolated(unsafe)` so `deinit` can stop updates. `Tools/audit_sources.py`
fails the build if any of these appears without a justification comment.

There are no `@preconcurrency` imports.

## Observation and update rates

Everything observable is `@Observable`. Because `@Observable` does not support
`didSet` on a tracked property, preferences that must persist are computed
properties over a tracked stored property, so writing one both notifies observers
and saves it — there is no separate `save()` a caller can forget.

| Stage | Rate |
|---|---|
| Core Motion samples | ~50 Hz requested; actual measured, never assumed |
| Pose sampling and raycasts | ≤60 Hz, rate-limited |
| HUD readouts | 10 Hz (`Theme.readoutUpdatesPerSecond`) |
| Diagnostics chart | 5 Hz, 60 points |
| Detector candidates | ≤1 per 350 ms refractory period |
| Haptics | ≤1 per 800 ms **per cluster** |

The HUD publishes a single `LiveReadout` struct rather than a dozen properties,
so a refresh invalidates the view once instead of once per number.

## Bounded everything

A scan can run for many minutes at 50 Hz against a 60 Hz camera. Every buffer has
a hard cap:

| Buffer | Cap |
|---|---|
| Detector smoothing window | 3 samples |
| Detector persistence window | 5 samples |
| Detector smoothed history | 8 samples |
| Pose ring buffer | 180 samples (~3 s) |
| Sample-rate tracker | 100 intervals |
| Rendered clusters | 250 |
| Stored measurements per scan | 5000, with the dropped count reported in exports |
| Diagnostic recording | 60 000 samples, then it stops and says so |

`BoundedBuffer` compacts its backing array so it never grows beyond twice its
capacity while still amortising the copy.

## Lifecycle

* Nothing starts while the user is reading the preparation checklist. The camera
  and the magnetometer start when they leave it.
* `ScanFlowView` tears the coordinator down on disappear and pauses it on any
  scene-phase change away from `.active`.
* The idle timer is disabled **only** while actively measuring, and restored on
  pause, finish, teardown, backgrounding and any blocking problem — plus an
  app-level backstop in `WallFieldApp` for anything missed.
* `MagneticFieldProviding.start` is idempotent: it stops any previous stream
  first, so there is never more than one Core Motion subscription or live
  continuation. Exactly one `CMMotionManager` exists per service.
* Diagnostics stops its stream on disappear and on backgrounding.

## Rendering

RealityKit only; there is no SceneKit and no `ARSCNView`, both deprecated from
the iOS 26 SDK. `Tools/audit_sources.py` enforces this.

* Detected walls render as translucent blue geometry built from ARKit's
  **boundary polygon** where one exists, falling back to the plane's rectangular
  extent. Triangles are emitted with both windings so the overlay is visible from
  either side without depending on a material face-culling setting.
* Entities are created once and updated in place. ARKit refines planes several
  times a second; rebuilding entities each time would churn GPU resources for no
  visual benefit.
* Expensive render features (motion blur, depth of field, HDR, camera grain,
  grounding shadows) are switched off. None of them helps read a heat map and all
  of them cost power over a long scan.
* Scene depth and mesh reconstruction are **queried and reported but not
  enabled**. The primary experience must be identical on iPhones without LiDAR,
  so the app does not depend on depth and does not pay for it.

## Accessibility

* No state is conveyed by colour alone. Strength bands carry distinct SF Symbols;
  unconfirmed markers render as rings while repeated markers render filled with a
  bright centre; the legend and 2D map label every state in words.
* There is deliberately **no green** in the palette, so a quiet reading cannot be
  rendered as an all-clear even by accident.
* Every readout has an accessibility label that reads as a sentence; clusters
  describe the measurement and never an object type.
* All text uses semantic `Font.TextStyle`s, so the interface scales with Dynamic
  Type. Controls over the camera are at least 48 pt.
* Reduce Motion removes the HUD's transitions.

## Where the rules live

The scientific and safety rules are enforced in code, not by memory:

* `Copy/SafetyCopy.swift` — every safety string, in one reviewable file.
* `SpatialMapping/ScanQualityGate.swift` — the only place a marker may be
  authorised. Nothing else can place one.
* `Models/DetectorConfiguration.swift` — every tunable constant, versioned and
  stored with each scan.
* `Tools/lint_claims.py` — fails on a banned marketing phrase anywhere, and on a
  guarded phrase such as "safe to drill" appearing without a negation.

# Algorithm

Everything below is implemented in `WallField/Detection` and
`WallField/SpatialMapping`, and every constant lives in
`WallField/Models/DetectorConfiguration.swift`.

> **The thresholds in this build are provisional.** They were chosen to be
> conservative — to favour missing a real anomaly over inventing one — and have
> not been measured against known physical ground truth.
> `AlgorithmVersion.current` carries a `-provisional` suffix, the app says so in
> Diagnostics and on every saved scan, and
> [`VALIDATION_PROTOCOL.md`](VALIDATION_PROTOCOL.md) defines what has to happen
> before that changes.

---

## 1. What is measured

`CMDeviceMotion.magneticField` — the total magnetic field around the device with
the device's own bias removed, carrying a calibration-accuracy estimate. Units
are microtesla throughout.

Detection runs on the **vector magnitude**, `sqrt(x² + y² + z²)`, not on any
single axis. Rotating the phone redistributes a static field between the axes but
leaves its magnitude unchanged, so hand rotation produces far fewer spurious
candidates. The full vector is retained for diagnostics and export.

Raw `magnetometerData` is available as a fallback but includes the phone's own
hard- and soft-iron bias and reports no accuracy. It is labelled *Raw
magnetometer*, shown only in Diagnostics, and
`MagneticFieldSource.isAcceptableForDetection` returns `false` for it — the
quality gate refuses it, so it can never anchor a marker.

## 2. Why there is no absolute threshold

There is deliberately no rule of the form "anything above 50 µT is metal".
Earth's field varies with location, and the indoor environment varies far more.
Any fixed absolute cut-off would be indefensible.

Detection is instead relative to a baseline measured **in this room, in this
session**, scaled by noise measured the same way, with a small absolute floor
used only to suppress changes that are statistically significant but physically
trivial.

## 3. Calibration

`CalibrationEngine` collects samples while the user holds the phone still against
the wall, and **refuses** rather than degrades when conditions are wrong. A
baseline measured while the phone was moving would not merely be imprecise — it
would silently mis-scale every z-score for the rest of the scan.

Accepted only if all of:

| Requirement | Constant | Default |
|---|---|---|
| Duration of accepted samples | `calibrationMinimumDuration` | 2.5 s |
| Accepted sample count | `calibrationMinimumSamples` | 100 |
| Calibration accuracy | `MagneticFieldAccuracy.minimumAcceptable` | Medium |
| Source | `isAcceptableForDetection` | calibrated device motion |
| Device held steady | `MotionEnergy.isSteady` | ≤0.06 g, ≤0.35 rad/s |
| AR tracking (scan flow only) | `TrackingQuality.permitsPlacement` | normal |
| Robust sigma | `calibrationMaximumSigma` | ≤1.5 µT |
| Peak-to-peak range | `calibrationMaximumRange` | ≤12 µT |
| Delivered sample stream | `SampleTimingHealth.isHealthy` | ≥20 Hz, no gap >150 ms |

Each failure maps to a distinct `CalibrationRejection` with plain-language
recovery text, and the engine resets so the next attempt starts clean.

### What calibration produces

* **Baseline** = the **median** of the magnitudes. A median, not a mean: during a
  real calibration a hand shakes, a car passes, someone walks by with a phone.
  One large outlier moves a mean noticeably and barely moves a median.
* **Sigma** = `1.4826 × MAD`, the median absolute deviation scaled to be a
  consistent estimator of the standard deviation for normally distributed data.

The MAD is computed on the **median-smoothed** series, using the same
median-of-*N* smoothing the online detector applies. Measuring noise on the raw
series and scoring on the smoothed one would make every z-score conservative by
an unknown factor; measuring both the same way means a z-score during scanning
means what it says.

* **The noise floor.** Sigma is floored at `minimumSigma` (0.15 µT). A perfectly
  quiet calibration measures zero variance, and without the floor every
  subsequent sample would be infinitely significant. The floor is recorded in the
  summary (`sigmaWasFloored`) so it is visible rather than hidden.

Raw MAD, range, sample count, duration, worst accuracy, measured rate and source
are all stored with the scan.

## 4. Online detection

`OnlineAnomalyDetector.ingest(_:)`, one pass per sample, all O(1).

### 4.1 Median smoothing

A rolling **median** over `smoothingWindow` (3) samples. A median, not a mean, so
a single wild sample is discarded outright rather than averaged in.

**Nothing may arm until the window is full.** With an empty window the smoothing
is not yet in force; without this guard a burst arriving in the first samples
after calibration — precisely when the window is empty — could reach the
persistence rule intact. This was a real defect, found by
`Tools/verify_algorithm.py`, and `testSpikeOnTheVeryFirstSamplesAfterCalibrationIsIgnored`
is its regression test.

### 4.2 Deviation and score

```
delta = smoothed − slowBaseline                     (signed, µT)
z     = |delta| / sigma                              (robust z-score)
```

Both polarities are detected. Ferrous material can concentrate the local field or
shield it, so a drop below baseline is as real a measurement as a rise.

A short-term **gradient** (change in the smoothed magnitude over
`gradientLookback` = 5 samples, µT/s) is recorded for diagnostics and validation.

### 4.3 The dual threshold

A candidate must clear **both**:

```
z ≥ enterZScore                    adaptive: scaled by this session's noise
|delta| ≥ absoluteFloorMicrotesla  absolute: a physical minimum
```

The adaptive term stops a noisy environment producing marks. The absolute floor
stops an unusually quiet environment promoting a physically meaningless wobble
just because it is statistically large.

### 4.4 Persistence

At least `persistenceRequired` of the last `persistenceWindow` samples must clear
the threshold. Combined with median-of-3 smoothing, this gives a property worth
stating exactly, because it is what "no isolated sample creates a marker" means
in practice:

| Consecutive elevated samples | Candidate? |
|---|---|
| 1 | No — the median discards it entirely |
| 2 | No — persistence peaks at 2 of 5 |
| 3 or more | Yes |

At 50 Hz that is a minimum of ~60 ms of sustained evidence, roughly 2 cm of
travel at the maximum permitted scan speed.

### 4.5 Hysteresis

Once an event is active it ends only when the signal falls below **lower** exit
thresholds (`exitZScore`, and `exitFloorFraction × absoluteFloor`), so a reading
hovering at the boundary does not chatter on and off.

### 4.6 Refractory period

At most one candidate per `refractoryInterval` (350 ms). One physical peak
therefore yields a handful of candidates for the cluster engine to merge, rather
than fifty. Without it, two seconds over one feature would emit ~100 candidates.

### 4.7 Baseline adaptation

The slow baseline follows genuine environmental drift with an exponential moving
average of time constant `baselineTimeConstant`:

```
alpha = 1 − exp(−dt / tau)
baseline += alpha × (smoothed − baseline)
```

It updates **only** while the detector is idle *and* `z < baselineUpdateMaxZScore`.
Otherwise a real anomaly would quietly become the new normal and erase itself —
a long pass over one feature would stop reporting it.

`tau` and `baselineUpdateMaxZScore` are chosen **together**. A baseline following
a steady drift of *r* µT/s lags it by `r × tau`; that lag must stay below the
z-score at which adaptation stops, or the baseline freezes and ordinary drift
eventually looks like an anomaly. At 5 s and 3 sigma the detector absorbs roughly
0.1 µT/s indefinitely — far faster than a room drifts — while leaving a clear gap
below the 5 sigma detection threshold.

### 4.8 Score

A normalised `0…1` value used only for rendering intensity and ordering. **Not a
probability, and not a confidence.**

```
score = 0.35
      + 0.35 × min(1, (z − enterZ) / enterZ)
      + 0.30 × min(1, |delta| / (4 × absoluteFloor))
```

It blends how far past the statistical threshold a reading is with how far past
the physical floor, so a reading that is only statistically large — in an
unusually quiet room — does not outrank one that is also physically large.

## 5. Sensitivity presets

Presets change the **statistical thresholds only**. No preset makes the app able
to identify what caused a reading.

| | Low | Medium (default) | High |
|---|---|---|---|
| `enterZScore` | 7.0 | 5.0 | 4.0 |
| `exitZScore` | 4.5 | 3.0 | 2.5 |
| `absoluteFloorMicrotesla` | 6.0 | 4.0 | 2.5 |
| `persistenceRequired` (of 5) | 4 | 3 | 3 |

The exact configuration a scan ran with is persisted in the record, so a scan
opened after the defaults change is still interpretable.

## 6. Synchronising sensor data with space

Core Motion and ARKit deliver on independent callbacks. Taking "whatever pose is
current when the sensor callback happens to run" silently attributes a reading to
wherever the phone drifted to in the meantime.

Instead:

1. Every pose sample is stamped with `systemUptime` **inside** the render
   callback and appended to a 180-entry ring buffer.
2. Each candidate is matched to the **nearest** pose within
   `timestampTolerance` (100 ms).
3. If nothing is close enough, the live reading is still shown but **no marker is
   anchored**.
4. The achieved timing error is stored with the measurement and summarised per
   scan, so the tolerance can be revisited against real data.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) → *Time basis* for why the two framework
clocks are not assumed to share an epoch, and how that assumption is verified on
a device.

## 7. Scan-quality gates

`ScanQualityGate` is the only place in the app that can authorise a marker. All
of the following must hold:

1. magnetic data is available;
2. the source is calibrated device motion, not raw magnetometer;
3. the delivered sample stream is healthy;
4. calibration accuracy is at least Medium;
5. a baseline exists;
6. a wall is locked;
7. the detector reports persistent evidence, not one noisy sample;
8. a pose exists within the timestamp tolerance;
9. AR tracking is normal;
10. camera speed is within `maximumScanSpeed` (0.35 m/s);
11. the raycast hit the locked wall;
12. distance to the wall is within `[minimumWallDistance, maximumWallDistance]`
    (2 cm – 35 cm);
13. the cluster cap has not been reached.

A hit that misses the mapped geometry but lands on the locked plane's infinite
extension within `maximumExtrapolationDistance` (10 cm) is **accepted but
downgraded** to `.extrapolatedPlane`, and that reduced spatial quality is stored
with the measurement and the cluster. Beyond that margin there is no hit at all.

When a gate fails, the UI names the specific condition — *Move more slowly*,
*Point at the selected wall*, *Improve lighting*, *Magnetic calibration needed*,
*Hold the phone steady* — rather than saying "poor quality".

## 8. Clustering

`ClusterEngine` merges accepted candidates that land within `clusterRadius`
(4 cm) of an existing cluster in wall space. Without it, a 50 Hz stream would
leak one RealityKit entity per sample and present a smear of markers as though
many separate things had been found. **One physical region produces one marker.**

A merge updates:

* the **score-weighted centroid** in wall space, anchor space and world space;
* peak signed delta, peak z-score and peak score (largest magnitude wins,
  whichever sign);
* sample count, first and last seen;
* best raycast quality and **worst** timing error — the pessimistic bound, so
  quality is never overstated;
* pass membership.

### Repeat-pass confidence

A cluster is `.repeated` only when a **later pass** measured the same place again:
the pass index must be new *and* at least `repeatPassMinimumInterval` (2 s) must
have elapsed since the cluster's last contribution. Tapping *New pass* mid-sweep
cannot promote a reading without new evidence.

**A single pass stays `Unconfirmed` however large its reading was.** One pass
cannot distinguish a real feature from a transient.

### What confidence means

> Confidence describes how sure WallField is that a **repeatable magnetic
> anomaly** was measured at approximately that spot on the wall. It says nothing
> about what caused the anomaly, how deep it is, or whether the area is safe to
> work on.

## 9. Verification

`WallFieldTests` covers each stage with synthetic data — quiet-field
false-positive resistance, both polarities, isolated-spike rejection, the
persistence boundary, hysteresis, refractory bounds, drift absorption, preset
ordering, timestamp matching, every gate, clustering and repeat-pass rules.

Because this repository was built where no Swift toolchain exists,
`Tools/detector_reference.py` is a line-by-line Python port of the arithmetic and
`Tools/verify_algorithm.py` checks the same 81 expectations the XCTests assert.
It is **not** a substitute for running the XCTest suite — it does not compile
Swift and cannot catch a Swift error — but an algorithm that is wrong is wrong in
Swift too, and it found the warm-up defect described in §4.1.

## 10. Known limits of the algorithm

* A field alternating at close to the sampling rate defeats median smoothing, as
  it defeats any median filter. Such a field cannot pass calibration
  (`fieldTooNoisy`), so a scan cannot start in one.
* Wall-space coordinates depend on the captured `WallFrame`. A large ARKit
  relocalisation invalidates it; the app ends the scan rather than remapping.
* The absolute floor is expressed in µT and is not distance-compensated. A weak
  source close to the phone and a strong source further away can produce the same
  reading. Nothing in the app claims otherwise, and depth is never reported.
* Every threshold is provisional until measured against physical ground truth.

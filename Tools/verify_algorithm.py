#!/usr/bin/env python3
"""Runs every scenario asserted by `WallFieldTests` against the Python reference
port in `Tools/detector_reference.py`, and checks the same expectations.

This does **not** compile or run the Swift. It checks that the arithmetic the
Swift implements produces the results the Swift tests assert, so an algorithmic
mistake -- or a test that asserts something the algorithm cannot deliver -- is
caught before anyone opens Xcode.

Run: ``python3 Tools/verify_algorithm.py``
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from detector_reference import (  # noqa: E402
    PRESETS, CalibrationEngine, DeterministicRandom, Sample,
    calibrated, median, median_absolute_deviation, noise, robust_z, rolling_median,
    run, stream, MAD_TO_SIGMA,
)

failures: list[str] = []
passed = 0


def expect(condition: bool, message: str) -> None:
    global passed
    if condition:
        passed += 1
    else:
        failures.append(message)


def close(a, b, tolerance):
    return abs(a - b) <= tolerance


# ============================================================ statistics
def check_statistics() -> None:
    expect(median([5, 1, 3]) == 3, "median of odd count")
    expect(median([1, 2, 3, 4]) == 2.5, "median of even count")
    expect(median([]) is None, "median of empty is None")
    expect(median_absolute_deviation([1, 2, 3, 4, 5]) == 1, "MAD of 1..5 is 1")
    expect(close(MAD_TO_SIGMA * median_absolute_deviation([1, 2, 3, 4, 5]),
                 MAD_TO_SIGMA, 1e-9), "robust sigma applies the 1.4826 scale factor")
    expect(robust_z(60, 48, 0) == 0, "z is zero for a zero sigma")
    expect(robust_z(60, 48, -1) == 0, "z is zero for a negative sigma")
    expect(close(robust_z(50, 48, 0.5), 4, 1e-9), "z is symmetric (up)")
    expect(close(robust_z(46, 48, 0.5), 4, 1e-9), "z is symmetric (down)")

    clean = [48.0, 48.1, 47.9, 48.05, 47.95]
    contaminated = clean + [900.0]
    expect(close(median(clean), median(contaminated), 0.1),
           "median resists a single wild outlier")
    mean_clean = sum(clean) / len(clean)
    mean_dirty = sum(contaminated) / len(contaminated)
    expect(abs(mean_dirty - mean_clean) > 100,
           "the mean is badly affected, which is why it is not used")

    smoothed = rolling_median([1.0, 100.0, 1.0, 1.0, 1.0], 3)
    expect(smoothed == [1, 50.5, 1, 1, 1], f"rolling median warm-up: {smoothed}")

    # The generator must be reproducible run to run.
    a = [DeterministicRandom(7).gaussian() for _ in range(1)]
    b = [DeterministicRandom(7).gaussian() for _ in range(1)]
    expect(a == b, "DeterministicRandom is reproducible for a fixed seed")
    values = noise(1.0, 5000)
    mean = sum(values) / len(values)
    expect(abs(mean) < 0.05, f"synthetic noise is zero-mean (got {mean:.4f})")


# ============================================================ calibration
def calibrate(samples, tracking="normal", require_tracking=True):
    engine = CalibrationEngine(PRESETS["medium"])
    last = ("collecting", 0.0)
    for sample in samples:
        last = engine.ingest(sample, tracking, require_tracking)
        if last[0] in ("rejected", "completed"):
            return last
    return last


def check_calibration() -> None:
    config = PRESETS["medium"]

    n = noise(0.15, 200)
    kind, summary = calibrate(stream(200, lambda i: 48.0 + n[i]))
    expect(kind == "completed", f"a steady field calibrates (got {kind})")
    if kind == "completed":
        expect(close(summary["baseline"], 48, 0.2),
               f"baseline is the quiet median (got {summary['baseline']:.3f})")
        expect(summary["sigma"] > 0, "sigma is positive")
        expect(summary["sigma"] < config.calibration_maximum_sigma, "sigma is under the limit")
        expect(summary["duration"] >= config.calibration_minimum_duration,
               "duration requirement met")
        expect(summary["sample_count"] >= config.calibration_minimum_samples,
               "sample-count requirement met")
        expect(close(summary["rate"], 50, 1), f"measured rate (got {summary['rate']:.2f})")

    n = noise(0.4, 200)
    kind, summary = calibrate(stream(200, lambda i: 48.0 + n[i]))
    expect(kind == "completed", "a moderately noisy but steady field still calibrates")
    if kind == "completed":
        expect(close(summary["sigma"], MAD_TO_SIGMA * summary["mad"], 1e-9),
               "sigma == 1.4826 x MAD when not floored")
        expect(summary["floored"] is False, "sigma was not floored at 0.4 uT of noise")

    kind, summary = calibrate(stream(200, lambda i: 48.0))
    expect(kind == "completed", "a perfectly quiet field calibrates")
    if kind == "completed":
        expect(summary["mad"] == 0, "MAD is zero for a constant field")
        expect(close(summary["sigma"], config.minimum_sigma, 1e-12),
               "sigma is raised to the learned noise floor")
        expect(summary["floored"] is True, "the floor is reported")

    n = noise(4.0, 300)
    kind, reason = calibrate(stream(300, lambda i: 48.0 + n[i]))
    expect((kind, reason) == ("rejected", "fieldTooNoisy"),
           f"an unsettled field is refused (got {kind}/{reason})")

    kind, reason = calibrate(stream(200, lambda i: 48.0, accuracy="low"))
    expect((kind, reason) == ("rejected", "accuracyTooLow"), "low accuracy is refused")

    kind, reason = calibrate(stream(200, lambda i: 48.0, accuracy="uncalibrated"))
    expect((kind, reason) == ("rejected", "accuracyTooLow"), "uncalibrated data is refused")

    kind, reason = calibrate(stream(200, lambda i: 48.0, source="rawMagnetometer"))
    expect((kind, reason) == ("rejected", "unsupportedSource"), "raw magnetometer is refused")

    kind, reason = calibrate(stream(200, lambda i: 48.0, steady=False))
    expect((kind, reason) == ("rejected", "excessiveMotion"), "a moving phone is refused")

    kind, reason = calibrate(stream(200, lambda i: 48.0), tracking="limited")
    expect((kind, reason) == ("rejected", "trackingNotNormal"), "limited tracking is refused")

    kind, _ = calibrate(stream(200, lambda i: 48.0), tracking="notAvailable",
                        require_tracking=False)
    expect(kind == "completed", "diagnostics calibration ignores AR tracking")

    kind, reason = calibrate(stream(200, lambda i: 48.0, interval=0.2))
    expect((kind, reason) == ("rejected", "sampleTimingUnstable"),
           f"a stalling stream is refused (got {kind}/{reason})")

    import math
    kind, reason = calibrate(stream(300, lambda i: 48.0 + 9.0 * math.sin(i * 0.05)))
    expect(kind == "rejected" and reason in ("fieldRangeTooLarge", "fieldTooNoisy"),
           f"a swinging field is refused (got {kind}/{reason})")

    # Progress is monotonic and never reaches 1 before completion.
    engine = CalibrationEngine(config)
    fractions = []
    for sample in stream(60, lambda i: 48.0):
        kind, value = engine.ingest(sample)
        if kind == "collecting":
            fractions.append(value)
    expect(len(fractions) == 60, "progress reported for every sample")
    expect(all(a <= b for a, b in zip(fractions, fractions[1:])), "progress is monotonic")
    expect(fractions[-1] < 1, "progress stays below 1 until completion")

    # Rejection resets the engine.
    engine = CalibrationEngine(config)
    for sample in stream(40, lambda i: 48.0):
        engine.ingest(sample)
    expect(engine.sample_count > 0, "engine accumulated samples")
    engine.ingest(Sample(timestamp=0, magnitude=48, accuracy="low"))
    expect(engine.sample_count == 0 and engine.elapsed == 0,
           "a rejection resets the engine")


# ============================================================ detector
def check_detector() -> None:
    config = PRESETS["medium"]

    d = calibrated()
    n = noise(0.2, 2000)
    candidates = run(d, stream(2000, lambda i: 48.0 + n[i]))
    expect(not candidates, f"a quiet field produces no candidates (got {len(candidates)})")

    from detector_reference import OnlineAnomalyDetector
    d = OnlineAnomalyDetector(config)
    candidates = run(d, stream(500, lambda i: 48.0 if i < 200 else 90.0))
    expect(not candidates and d.state == "uncalibrated",
           "an uncalibrated detector emits nothing")

    d = calibrated()
    d.invalidate()
    candidates = run(d, stream(300, lambda i: 48.0 if i < 100 else 60.0))
    expect(not candidates, "invalidating calibration stops detection")

    d = calibrated()
    candidates = run(d, stream(200, lambda i: 48.0 if i < 100 else 56.0))
    expect(len(candidates) >= 1, "an 8 uT step is detected")
    if candidates:
        first = candidates[0]
        expect(first.polarity == "positive", "positive polarity")
        expect(close(first.delta, 8, 0.5), f"delta is 8 uT (got {first.delta:.3f})")
        expect(first.z > 5, "z clears the threshold")
        expect(first.persistence >= config.persistence_required, "persistence requirement met")

    d = calibrated()
    candidates = run(d, stream(200, lambda i: 48.0 if i < 100 else 40.0))
    expect(len(candidates) >= 1 and candidates[0].polarity == "negative",
           "an 8 uT drop is detected with negative polarity")
    expect(candidates and candidates[0].delta < -4, "negative delta")

    d = calibrated()
    candidates = run(d, stream(200, lambda i: 48.0 if i < 100
                               else 48.0 + min((i - 100) * 0.5, 10)))
    expect(len(candidates) >= 1 and candidates[0].gradient > 0,
           "gradient is positive across a rising edge")

    d = calibrated()
    candidates = run(d, stream(300, lambda i: 88.0 if i == 150 else 48.0))
    expect(not candidates, f"a one-sample spike is ignored (got {len(candidates)})")

    d = calibrated()
    candidates = run(d, stream(300, lambda i: 88.0 if 150 <= i <= 151 else 48.0))
    expect(not candidates, f"a two-sample spike is ignored (got {len(candidates)})")

    d = calibrated()
    candidates = run(d, stream(300, lambda i: 60.0 if 150 <= i <= 152 else 48.0))
    expect(len(candidates) == 1,
           f"a three-sample burst yields exactly one candidate (got {len(candidates)})")

    d = calibrated()
    candidates = run(d, stream(600, lambda i: 88.0 if (i % 10) < 2 else 48.0))
    expect(not candidates,
           f"sixty repeated two-sample bursts never accumulate (got {len(candidates)})")

    d = calibrated()
    candidates = run(d, stream(300, lambda i: 88.0 if i < 2 else 48.0))
    expect(not candidates,
           f"a spike on the first samples after calibration is ignored (got {len(candidates)})")

    d = calibrated()
    candidates = run(d, stream(400, lambda i: 48.0 if i < 100 else 51.5))
    expect(not candidates,
           f"a 3.5 uT change is below the absolute floor (got {len(candidates)})")

    # Hysteresis
    d = calibrated()
    run(d, stream(60, lambda i: 48.0 if i < 20 else 56.0))
    expect(d.state != "idle", "the event is active after a sustained rise")
    run(d, stream(20, lambda i: 51.0, start=10_002.0))
    expect(d.state != "idle", "a dip inside the hysteresis band keeps the event active")
    run(d, stream(20, lambda i: 48.0, start=10_003.0))
    expect(d.state == "idle", "returning to baseline ends the event")

    # Refractory
    d = calibrated()
    candidates = run(d, stream(150, lambda i: 48.0 if i < 50 else 58.0))
    upper = int(2.0 / config.refractory) + 2
    expect(3 <= len(candidates) <= upper,
           f"a two-second peak yields 3..{upper} candidates (got {len(candidates)})")
    gaps = [b.timestamp - a.timestamp for a, b in zip(candidates, candidates[1:])]
    expect(all(g >= config.refractory - 1e-9 for g in gaps),
           f"candidates respect the refractory period (gaps {gaps})")

    # Baseline adaptation
    d = calibrated()
    candidates = run(d, stream(3000, lambda i: 48.0 + i * 0.02 * 0.1))
    expect(not candidates, f"slow drift is absorbed (got {len(candidates)} candidates)")
    expect(close(d.baseline, 54, 1.0),
           f"the baseline followed the drift (got {d.baseline:.3f}, expected ~54)")

    d = calibrated()
    run(d, stream(100, lambda i: 48.0))
    before = d.baseline
    run(d, stream(500, lambda i: 58.0, start=10_002.0))
    expect(close(d.baseline, before, 0.5),
           f"the baseline does not absorb an active anomaly ({before:.3f} -> {d.baseline:.3f})")

    # Sensitivity
    def count(preset):
        detector = calibrated(preset)
        return len(run(detector, stream(300, lambda i: 48.0 if i < 100 else 51.0)))

    expect(count("high") > 0, "High detects a 3 uT change")
    expect(count("medium") == 0, "Medium does not detect a 3 uT change")
    expect(count("low") == 0, "Low does not detect a 3 uT change")

    for preset in PRESETS:
        detector = calibrated(preset)
        found = run(detector, stream(300, lambda i: 48.0 if i < 100 else 68.0))
        expect(len(found) > 0, f"{preset} detects a 20 uT change")

    low, medium, high = PRESETS["low"], PRESETS["medium"], PRESETS["high"]
    expect(low.enter_z > medium.enter_z > high.enter_z, "presets ordered by z threshold")
    expect(low.absolute_floor > medium.absolute_floor > high.absolute_floor,
           "presets ordered by absolute floor")
    for name, preset in PRESETS.items():
        expect(preset.exit_z < preset.enter_z, f"{name} has a hysteresis band")

    # Score bounds
    from detector_reference import Candidate
    small = Candidate(0, 4.1, 5.1, 0, 3, 0.2, 52.1, 48)
    large = Candidate(0, 40, 60, 0, 5, 0.2, 88, 48)
    expect(0 <= small.score(config) <= 1, "small score is bounded")
    expect(0 <= large.score(config) <= 1, "large score is bounded")
    expect(small.score(config) < large.score(config), "scores are ordered by strength")


def main() -> int:
    check_statistics()
    check_calibration()
    check_detector()
    print(f"verify_algorithm.py: {passed + len(failures)} expectations, "
          f"{len(failures)} failure(s)")
    for failure in failures:
        print("  FAIL " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

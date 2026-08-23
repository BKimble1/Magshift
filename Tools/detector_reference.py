#!/usr/bin/env python3
"""A line-by-line Python port of WallField's detection arithmetic.

## What this is, and what it is not

There is no Swift toolchain in this environment, so `WallFieldTests` cannot be
executed here. This module exists so the *algorithm* and the *expectations
encoded in those tests* can still be checked numerically before anyone runs them
on a Mac.

It is **not** a substitute for running the XCTest suite: it does not compile the
Swift, it cannot catch a Swift type error, and it will not notice if the Swift
and this port drift apart. It answers exactly one question -- "given these
inputs, does this arithmetic produce the result the test asserts?" -- and that
question is worth answering, because an algorithm that is wrong is wrong in
Swift too.

Ported from:
  WallField/Detection/RobustStatistics.swift
  WallField/Detection/CalibrationEngine.swift
  WallField/Detection/OnlineAnomalyDetector.swift
  WallField/Sensors/SimulatedEnvironment.swift (DeterministicRandom)
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

MASK64 = (1 << 64) - 1
MAD_TO_SIGMA = 1.4826


# ---------------------------------------------------------------- randomness
class DeterministicRandom:
    """Mirrors `DeterministicRandom` (xorshift64, Box-Muller)."""

    def __init__(self, seed: int = 0x5741_4C4C_4649_454C):
        self.state = seed & MASK64 or 1

    def next(self) -> int:
        s = self.state
        s ^= (s << 13) & MASK64
        s ^= s >> 7
        s ^= (s << 17) & MASK64
        self.state = s & MASK64
        return self.state

    def unit(self) -> float:
        return (self.next() >> 11) * (1.0 / 9007199254740992.0)

    def gaussian(self) -> float:
        u1 = max(self.unit(), 1e-12)
        u2 = self.unit()
        return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)


# ---------------------------------------------------------------- statistics
def median(values):
    if not values:
        return None
    s = sorted(values)
    mid = len(s) // 2
    if len(s) % 2 == 0:
        return (s[mid - 1] + s[mid]) / 2
    return s[mid]


def median_absolute_deviation(values):
    centre = median(values)
    if centre is None:
        return None
    return median([abs(v - centre) for v in values])


def robust_z(value, centre, sigma):
    if sigma <= 0:
        return 0.0
    return abs(value - centre) / sigma


# ---------------------------------------------------------------- config
@dataclass
class Config:
    enter_z: float
    exit_z: float
    absolute_floor: float
    exit_floor_fraction: float = 0.6
    persistence_required: int = 3
    persistence_window: int = 5
    smoothing_window: int = 3
    minimum_sigma: float = 0.15
    baseline_tau: float = 5.0
    baseline_update_max_z: float = 3.0
    gradient_lookback: int = 5
    refractory: float = 0.35
    calibration_minimum_duration: float = 2.5
    calibration_minimum_samples: int = 100
    calibration_maximum_sigma: float = 1.5
    calibration_maximum_range: float = 12.0


PRESETS = {
    "low": Config(enter_z=7.0, exit_z=4.5, absolute_floor=6.0, persistence_required=4),
    "medium": Config(enter_z=5.0, exit_z=3.0, absolute_floor=4.0, persistence_required=3),
    "high": Config(enter_z=4.0, exit_z=2.5, absolute_floor=2.5, persistence_required=3),
}


# ---------------------------------------------------------------- calibration
@dataclass
class Sample:
    timestamp: float
    magnitude: float
    interval: float = 0.02
    accuracy: str = "high"          # uncalibrated | low | medium | high
    source: str = "simulated"       # calibratedDeviceMotion | rawMagnetometer | simulated
    steady: bool = True


ACCURACY_RANK = {"uncalibrated": -1, "low": 0, "medium": 1, "high": 2}


def rolling_median(values, window):
    if window <= 1:
        return list(values)
    out, recent = [], []
    for value in values:
        recent.append(value)
        if len(recent) > window:
            recent.pop(0)
        out.append(median(recent))
    return out


class CalibrationEngine:
    """Mirrors `CalibrationEngine`."""

    def __init__(self, config: Config):
        self.config = config
        self.reset()

    def reset(self):
        self.magnitudes = []
        self.intervals = []
        self.accuracies = []
        self.start = None
        self.last = None

    @property
    def elapsed(self):
        if self.start is None or self.last is None:
            return 0.0
        return max(0.0, self.last - self.start)

    @property
    def sample_count(self):
        return len(self.magnitudes)

    def ingest(self, sample: Sample, tracking="normal", require_tracking=True):
        if sample.source == "rawMagnetometer":
            self.reset()
            return ("rejected", "unsupportedSource")
        if ACCURACY_RANK[sample.accuracy] < ACCURACY_RANK["medium"]:
            self.reset()
            return ("rejected", "accuracyTooLow")
        if require_tracking and tracking != "normal":
            self.reset()
            return ("rejected", "trackingNotNormal")
        if not sample.steady:
            self.reset()
            return ("rejected", "excessiveMotion")

        if self.start is None:
            self.start = sample.timestamp
        self.last = sample.timestamp
        self.magnitudes.append(sample.magnitude)
        self.accuracies.append(sample.accuracy)
        if sample.interval > 0:
            self.intervals.append(sample.interval)

        if (self.sample_count >= self.config.calibration_minimum_samples
                and self.elapsed >= self.config.calibration_minimum_duration):
            return self.finish()
        fraction = min(1.0, max(0.0, min(
            self.elapsed / self.config.calibration_minimum_duration,
            self.sample_count / self.config.calibration_minimum_samples,
        )))
        return ("collecting", fraction)

    def finish(self):
        c = self.config
        if self.sample_count < 2:
            self.reset()
            return ("rejected", "notEnoughSamples")
        if self.elapsed < c.calibration_minimum_duration:
            self.reset()
            return ("rejected", "notEnoughDuration")

        baseline = median(self.magnitudes)
        raw_mad = median_absolute_deviation(self.magnitudes)
        value_range = max(self.magnitudes) - min(self.magnitudes)
        smoothed = rolling_median(self.magnitudes, c.smoothing_window)
        smoothed_mad = median_absolute_deviation(smoothed)

        unfloored = MAD_TO_SIGMA * smoothed_mad
        sigma = max(unfloored, c.minimum_sigma)
        floored = sigma > unfloored

        if unfloored > c.calibration_maximum_sigma:
            self.reset()
            return ("rejected", "fieldTooNoisy")
        if value_range > c.calibration_maximum_range:
            self.reset()
            return ("rejected", "fieldRangeTooLarge")

        mean_interval = sum(self.intervals) / len(self.intervals) if self.intervals else 0.0
        rate = 1 / mean_interval if mean_interval > 0 else 0.0
        max_gap = max(self.intervals) if self.intervals else 0.0
        healthy = self.sample_count >= 10 and rate >= 20 and max_gap <= 0.15
        if not healthy:
            self.reset()
            return ("rejected", "sampleTimingUnstable")

        summary = {
            "baseline": baseline,
            "sigma": sigma,
            "mad": smoothed_mad,
            "raw_mad": raw_mad,
            "floored": floored,
            "range": value_range,
            "sample_count": self.sample_count,
            "duration": self.elapsed,
            "rate": rate,
            "worst_accuracy": min(self.accuracies, key=lambda a: ACCURACY_RANK[a]),
        }
        self.reset()
        return ("completed", summary)


# ---------------------------------------------------------------- detector
@dataclass
class Candidate:
    timestamp: float
    delta: float
    z: float
    gradient: float
    persistence: int
    sigma: float
    smoothed: float
    baseline: float

    @property
    def polarity(self):
        return "positive" if self.delta >= 0 else "negative"

    def score(self, config: Config) -> float:
        z_headroom = max(0.0, self.z - config.enter_z)
        z_term = z_headroom / max(config.enter_z, 0.001)
        magnitude_term = abs(self.delta) / max(config.absolute_floor * 4, 0.001)
        blended = 0.35 + 0.35 * min(1.0, z_term) + 0.30 * min(1.0, magnitude_term)
        return min(1.0, max(0.0, blended))


class OnlineAnomalyDetector:
    """Mirrors `OnlineAnomalyDetector`."""

    def __init__(self, config: Config):
        self.config = config
        self.phase = "uncalibrated"
        self.baseline = None
        self.sigma = None
        self.smoothing = []
        self.smoothed_history = []          # list of (timestamp, value)
        self.exceedance = []
        self.last_emission = None
        self.last_timestamp = None

    @property
    def state(self):
        if self.phase != "active":
            return self.phase
        if (self.last_emission is not None and self.last_timestamp is not None
                and self.last_timestamp - self.last_emission < self.config.refractory):
            return "refractory"
        return "active"

    def adopt(self, baseline: float, sigma: float):
        self.baseline = baseline
        self.sigma = max(sigma, self.config.minimum_sigma)
        self.phase = "idle"
        self._clear()

    def invalidate(self):
        self.baseline = None
        self.sigma = None
        self.phase = "uncalibrated"
        self._clear()

    def _clear(self):
        self.smoothing = []
        self.smoothed_history = []
        self.exceedance = []
        self.last_emission = None
        self.last_timestamp = None

    def _interval(self, sample: Sample) -> float:
        c = self.config
        if sample.interval > 0 and math.isfinite(sample.interval):
            return min(sample.interval, c.baseline_tau)
        if self.last_timestamp is not None and sample.timestamp > self.last_timestamp:
            return min(sample.timestamp - self.last_timestamp, c.baseline_tau)
        return 0.02

    def _gradient(self) -> float:
        k = self.config.gradient_lookback
        if len(self.smoothed_history) < k + 1:
            return 0.0
        newest_t, newest_v = self.smoothed_history[-1]
        older_t, older_v = self.smoothed_history[-1 - k]
        dt = newest_t - older_t
        if dt <= 0:
            return 0.0
        return (newest_v - older_v) / dt

    def ingest(self, sample: Sample):
        c = self.config
        if not (math.isfinite(sample.timestamp) and math.isfinite(sample.magnitude)):
            return None

        self.smoothing.append(sample.magnitude)
        if len(self.smoothing) > c.smoothing_window:
            self.smoothing.pop(0)
        smoothed = median(self.smoothing)

        self.smoothed_history.append((sample.timestamp, smoothed))
        capacity = max(c.gradient_lookback + 1, 8)
        if len(self.smoothed_history) > capacity:
            self.smoothed_history.pop(0)

        if self.sigma is None or self.baseline is None:
            self.last_timestamp = sample.timestamp
            return None

        delta = smoothed - self.baseline
        z = robust_z(smoothed, self.baseline, self.sigma)
        gradient = self._gradient()

        warming_up = len(self.smoothing) < c.smoothing_window
        clears_enter = (not warming_up
                        and z >= c.enter_z and abs(delta) >= c.absolute_floor)
        clears_sustain = (not warming_up
                          and z >= c.exit_z
                          and abs(delta) >= c.absolute_floor * c.exit_floor_fraction)

        self.exceedance.append(clears_enter)
        if len(self.exceedance) > c.persistence_window:
            self.exceedance.pop(0)
        persistence = sum(1 for e in self.exceedance if e)

        emitted = None

        def refractory_elapsed():
            if self.last_emission is None:
                return True
            return sample.timestamp - self.last_emission >= c.refractory

        if self.phase in ("idle", "arming"):
            if clears_enter:
                self.phase = "arming"
                if persistence >= c.persistence_required and refractory_elapsed():
                    self.phase = "active"
                    self.last_emission = sample.timestamp
                    emitted = Candidate(sample.timestamp, delta, z, gradient,
                                        persistence, self.sigma, smoothed, self.baseline)
            else:
                self.phase = "idle"
        elif self.phase == "active":
            if clears_sustain:
                if clears_enter and persistence >= c.persistence_required and refractory_elapsed():
                    self.last_emission = sample.timestamp
                    emitted = Candidate(sample.timestamp, delta, z, gradient,
                                        persistence, self.sigma, smoothed, self.baseline)
            else:
                self.phase = "idle"

        if self.phase == "idle" and z < c.baseline_update_max_z:
            dt = self._interval(sample)
            alpha = 1 - math.exp(-dt / c.baseline_tau)
            self.baseline += alpha * (smoothed - self.baseline)

        self.last_timestamp = sample.timestamp
        return emitted


# ---------------------------------------------------------------- helpers
def stream(count, magnitude_fn, interval=0.02, start=10_000.0, **kwargs):
    out = []
    for i in range(count):
        out.append(Sample(
            timestamp=start + i * interval,
            magnitude=magnitude_fn(i),
            interval=0.0 if i == 0 else interval,
            **kwargs,
        ))
    return out


def noise(sigma, count, seed=42):
    rng = DeterministicRandom(seed)
    return [rng.gaussian() * sigma for _ in range(count)]


def run(detector: OnlineAnomalyDetector, samples):
    return [c for c in (detector.ingest(s) for s in samples) if c is not None]


def calibrated(preset="medium", baseline=48.0, sigma=0.2):
    config = PRESETS[preset]
    detector = OnlineAnomalyDetector(config)
    detector.adopt(baseline, sigma)
    return detector

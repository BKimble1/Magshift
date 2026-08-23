# Safety and limitations

This document is the authority for what WallField may and may not say. The
strings the app displays live in `WallField/Copy/SafetyCopy.swift`;
`Tools/lint_claims.py` enforces the wording rules across the whole repository.

---

## The statement

> WallField measures local magnetic-field changes using the iPhone's sensors. It
> cannot identify every hidden object, determine whether wiring is present or
> energized, measure object depth, or confirm that a location is safe to drill.
> Use certified detection equipment and appropriate professional guidance before
> drilling.

This exact paragraph appears in onboarding, on the scan screen's safety sheet, on
every saved result, in every exported file, and in the App Review notes. It is a
single constant (`SafetyCopy.canonicalStatement`) so it cannot drift between
those places.

## The physics

**1. The magnetometer measures the field at the phone.** It does not image
through drywall. There is no imaging of any kind. A "map" produced by WallField
is a record of where the phone was when the field changed, not a picture of
anything inside a wall.

**2. A magnetic anomaly has many possible causes.** Screws, nails, ferrous
framing, pipes, appliances, speakers, chargers, a magnetic phone case, a MagSafe
accessory, the phone itself, or interference from something entirely unrelated to
the wall. WallField cannot distinguish between them and never tries.

**3. Many wall materials are not magnetic.** Plastic, most plumbing in modern
construction, aluminium, timber and plasterboard produce no useful signal. A
quiet reading across a whole wall may simply mean there is nothing magnetic close
enough to the surface for the sensor to register.

**4. Wiring may produce little or no detectable field.** It depends on how much
current flows, how the conductors are arranged (paired conductors' fields largely
cancel), how far away the wire is, its orientation, and whether it is shielded. A
conductor carrying no current produces no current-related field at all. WallField
never identifies a reading as wiring and never reports whether a circuit is
carrying current.

**5. A missing anomaly is never evidence that a location is clear.** WallField
reports what it measured at the phone. There are many things it cannot measure.

**6. Distance matters, and depth is not recoverable.** The field from a small
source falls off steeply with distance. A weak source close to the surface and a
strong source further inside a wall can produce the same reading. WallField never
reports depth, because it cannot determine it.

## What the app is not allowed to do

These are enforced by code and by `Tools/lint_claims.py`, not by memory.

**Never label a measurement as an object.** A detected feature is a **Magnetic
anomaly** — never a wire, live wire, screw, stud, pipe, cable, nail, rebar or
"danger". Nothing in the data model can carry an object type;
`AnomalyCluster.label` returns `SafetyCopy.anomalyLabel` and nothing else.

**Never present anything as safe or clear.** There is no "safe" state, no "clear"
state and no green success treatment anywhere in the app. The palette contains no
green at all (`WallField/DesignSystem/Palette.swift`), so one cannot be rendered
by accident. A quiet result reads:

> **No strong anomaly measured**
> This does not mean the area is safe to drill.

The qualifying sentence is not optional — it is part of the `NoAnomalyStatement`
component, so it cannot be omitted at a call site, and the linter fails any file
that shows the headline without it.

**Never use these phrases**, in the app, in documentation, or in store listings:

<!-- lint-allow-banned-phrase: begin -- this list is the prohibition itself. -->
X-ray; seeing through a wall; stud finder; metal, wire, cable, pipe or electrical
detector; professional-grade; finding hidden or live wires; detecting every
screw, pipe, stud or cable; knowing where it is acceptable to drill; any
guarantee of safety.
<!-- lint-allow-banned-phrase: end -->

**Never ask the user to do something dangerous.** WallField will never ask anyone
to open electrical equipment, expose conductors, or test the app against
energized wiring. `Docs/VALIDATION_PROTOCOL.md` requires ground truth to be
established before a wall is closed, or by a certified commercial detector or a
qualified professional — never by unsafe probing.

## What confidence means

> Confidence describes how sure WallField is that a repeatable magnetic anomaly
> was measured at approximately that spot on the wall. It says nothing about what
> caused the anomaly, how deep it is, or whether the area is safe to work on.

* **Unconfirmed** — seen on a single pass. A large reading on one pass is still
  unconfirmed.
* **Repeated** — measured again in the same place on a later pass, with
  acceptable data quality both times.

## Before you drill

* Use a certified wall scanner rated for the job.
* De-energize the relevant circuits at the panel and verify they are de-energized
  with appropriate equipment.
* Check building plans and follow local codes.
* Consult a qualified professional — an electrician, plumber or contractor — when
  you are unsure.
* Never treat a WallField result as clearance to drill, cut or fasten.

## Things that ruin a reading

Magnets near the phone overwhelm the sensor completely. A MagSafe wallet, a
magnetic mount, a magnetic case, a nearby speaker, a charger or a metal tool can
all produce readings far larger than anything in a wall. The preparation
checklist asks the user to remove them, calibration refuses to proceed when the
field is unsettled, and the scan screen names the specific problem when a gate
blocks a reading.

## How the app refuses bad data

Rather than presenting a low-quality reading with a caveat, WallField declines to
place it and says why:

| Condition | What the user sees |
|---|---|
| No magnetic data | Magnetic data unavailable |
| Calibration accuracy below Medium | Magnetic calibration needed |
| No baseline yet | Calibrate the field first |
| No wall locked | Select and lock a wall |
| AR tracking not normal | Improve lighting |
| Crosshair off the locked wall | Point at the selected wall |
| Moving faster than 0.35 m/s | Move more slowly |
| Outside 2–35 cm from the wall | Back off slightly / Move closer |
| No camera pose within 100 ms | Hold the phone steady |
| Sensor stream stalling | Sensor data is stalling |
| Only one or two samples | Hold over the spot a moment longer |
| Raw magnetometer only | Reduced-quality sensor data |

Every rejection is counted and reported in the saved scan's quality summary, so a
scan that produced few marks because conditions were poor can be told apart from
one that produced few marks because the wall was quiet.

## Provisional thresholds

The detection thresholds in this build have **not** been measured against known
physical ground truth. `AlgorithmVersion.current` carries a `-provisional`
suffix; Diagnostics, the review screen and every saved scan say so. No detection
claim may be made in App Store metadata until
[`VALIDATION_PROTOCOL.md`](VALIDATION_PROTOCOL.md) has been completed, and even
then a negative result never proves safety.

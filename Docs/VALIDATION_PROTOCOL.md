# Validation protocol

WallField's premise is a **hypothesis about hardware**: that an iPhone's
magnetometer, held against a wall and moved slowly, can register something
repeatable and spatially meaningful. That cannot be settled by reasoning or by
unit tests. It has to be measured against known ground truth on real devices.

This document is that experiment plan. Nothing in it has been performed —
this build was produced in an environment with no macOS, no Xcode and no
physical device — so every result column below is empty and must stay empty
until someone fills it in from a real measurement.

**No App Store claim about detecting anything may be made until §7 is complete.
Even after successful testing, a negative result never proves that a location is
safe.**

---

## 1. Safety rules for this protocol

These are not negotiable, and they are the reason some obvious experiments are
absent.

* **Ground truth is established before a wall is closed**, or by a certified
  commercial detector, or by a qualified professional. Never by probing,
  drilling exploratory holes, or cutting into an occupied wall.
* **Energized-wiring comparisons are performed only through a purpose-built,
  professionally constructed fixture, or by a qualified electrician.** Do not
  open equipment, expose conductors, or improvise a test rig.
* Test walls used for destructive verification must be **purpose-built panels**,
  not part of an occupied building.
* Anyone performing these tests should assume the app's output is meaningless
  until this protocol says otherwise.

## 2. Equipment

| Item | Purpose |
|---|---|
| Purpose-built test panels (see §3) | known ground truth |
| At least three iPhone models spanning the supported range | device-to-device variation |
| A certified commercial wall scanner | independent reference for closed walls |
| Non-magnetic tape measure and a marked grid overlay | spatial reference |
| Non-magnetic mount or brace | repeatable distance and orientation |
| Known ferrous samples: #8 × 50 mm screw, 75 mm nail, 16 mm steel plate | calibrated targets |
| Known non-ferrous samples: aluminium plate, PVC pipe, copper offcut | negative controls |

Record the make and model of every reference instrument in the log.

## 3. Test panels

Build at least two panels, 1.2 m × 1.2 m, standard 12.5 mm plasterboard on
timber studs at 400 mm centres. Photograph and dimension every item **before**
closing them.

**Panel A — discrete targets.** A grid of individually placed, isolated targets
at known coordinates, at three depths (surface, 15 mm, 40 mm behind the board):
one screw, one nail, one steel plate, one aluminium plate, one PVC pipe section,
and at least four **empty control cells** with nothing behind them at all.

**Panel B — construction realism.** Ordinary framing with steel fixings at
regular spacing, plus one region deliberately left free of fixings as a control.

Record every target's position in the panel's own coordinate system, in metres,
with the origin at the lower-left corner as seen from the front.

## 4. Method for a single run

1. Remove every magnetic accessory from the phone. Note the case, if any.
2. Open **Sensor diagnostics**, label the run (e.g. `PanelA-iPhone16-caseoff-9cm-pass1`),
   and record any relevant notes.
3. Calibrate over a control cell. Record baseline, MAD, sigma, whether sigma was
   floored, and the measured sample rate.
4. Start recording. Perform the pass at a marked, timed speed using the brace.
5. Stop recording and export both CSV and JSON.
6. Repeat each condition **at least three times**.

For scan-flow runs, use **New wall scan**, complete the same pass, save the scan
and export it. Tag the scan with the panel and cell identifiers using the
validation-tags field.

## 5. Conditions to cover

Every row is run on **every** device model in the set.

| # | Variable | Levels |
|---|---|---|
| 1 | Device model | ≥3 supported iPhone models |
| 2 | Accessories | all magnetic accessories removed / ordinary case on / MagSafe accessory attached |
| 3 | Phone orientation | portrait flat to wall / portrait rotated 90° in plane / landscape |
| 4 | Distance from wall | 2 cm, 5 cm, 9 cm, 20 cm, 35 cm |
| 5 | Scan speed | 0.05, 0.15, 0.25, 0.35, 0.6 m/s (the last deliberately above the gate) |
| 6 | Target type | screw / nail / steel plate / aluminium / PVC / empty control |
| 7 | Target depth | surface, 15 mm, 40 mm |
| 8 | Repeats | ≥3 passes per condition |
| 9 | Environmental interference | quiet room / charger 30 cm away / speaker 30 cm away / power tool 30 cm away / laptop on the other side of the wall |
| 10 | Lighting | normal room lighting / low light at the ARKit tracking limit |
| 11 | Sensitivity preset | Low / Medium / High on a fixed subset of the above |
| 12 | Wiring | de-energized vs energized, **through a professionally built fixture or by a qualified electrician only** |

## 6. What to record

For every run, from the exported files:

| Metric | Source | Target |
|---|---|---|
| Detection rate per known target | clusters CSV vs panel map | to be determined |
| False positives over empty control cells | clusters CSV | **the primary metric** |
| Spatial error, metres | cluster `wall_x_m`/`wall_y_m` vs panel map | to be determined |
| Repeatability across passes | cluster positions across ≥3 runs | to be determined |
| Peak delta vs distance | measurements CSV | characterises falloff |
| Peak delta vs target type | measurements CSV | which materials register at all |
| Measured sample rate | diagnostics preamble | ≥40 Hz sustained |
| Sensor-to-pose timing error | scan quality summary | mean and worst |
| Baseline and sigma per environment | calibration summary | informs `minimumSigma` |
| Observed Core Motion clock offset | diagnostics preamble | confirms the shared time basis |
| Calibration rejection rate and reasons | attempts log | informs the calibration limits |
| Device-to-device variation | all of the above, grouped by model | informs whether thresholds can be universal |

Keep every exported CSV and JSON. They are the evidence.

## 7. Release gate

Every one of these must be answered from measured data before any claim about
detection appears in App Store metadata:

- [ ] **False positives.** How many marks appear over empty control cells, per
      minute of scanning, per sensitivity preset? If this is not close to zero at
      Medium, the thresholds are wrong.
- [ ] **Detection.** Which target types and depths are detected at all? State it
      as a measured range, never as "detects screws".
- [ ] **Spatial accuracy.** What is the distribution of the distance between a
      mark and the target that caused it?
- [ ] **Repeatability.** Across three passes, how often does the same target
      produce a mark within `clusterRadius`?
- [ ] **Device variation.** Do the thresholds behave the same across models, or
      does the configuration need to vary by device?
- [ ] **Timing.** Is the 100 ms matching tolerance appropriate? Reduce it if the
      measured errors allow.
- [ ] **Noise floor.** Is `minimumSigma` (0.15 µT) above the real quiet-room
      noise of every tested device?
- [ ] **Speed gate.** Is 0.35 m/s the right cut-off, or does accuracy degrade
      earlier?
- [ ] **Battery and thermal.** A 15-minute continuous scan on each device: record
      battery consumed, thermal state reached, and whether frame rate degraded.
- [ ] **Interference.** How large are the readings from a nearby charger,
      speaker or tool compared with a real in-wall target? If they are
      comparable, the onboarding warning needs strengthening.

Only when these are answered may `AlgorithmVersion.current` drop its
`-provisional` suffix, and only then in a build whose thresholds were set from
the measured data.

## 8. Required physical-device checklist

Separately from the science, this functional checklist must be completed on a
supported physical iPhone before release. **None of it has been performed.**

| # | Check | Result |
|---|---|---|
| 1 | Camera permission grant, and denial with recovery | |
| 2 | Motion data availability reported correctly | |
| 3 | Vertical wall detection in normal light | |
| 4 | Vertical wall detection in low light | |
| 5 | Plane selection and locking | |
| 6 | Tracking interruption and recovery behaviour | |
| 7 | Stable baseline calibration with accessories removed | |
| 8 | Deliberately unstable calibration is rejected, with the right reason | |
| 9 | Actual sensor sample rate sustained over a long scan | |
| 10 | Spatial alignment of marks during slow passes | |
| 11 | Repeatability over known control points | |
| 12 | False positives over known empty regions | |
| 13 | Behaviour near chargers, speakers, tools, appliances and magnetic cases | |
| 14 | Battery and thermal behaviour over a ≥15-minute scan | |
| 15 | Save, export and delete after a real scan | |
| 16 | VoiceOver on the scan controls | |
| 17 | Largest Dynamic Type size on the scan controls | |
| 18 | Backgrounding mid-scan, and restoration | |
| 19 | Idle timer restored after every exit path | |
| 20 | A device with no LiDAR behaves identically to one with LiDAR | |

## 9. Reporting

Write results into this file, with the date, device models, firmware versions,
app version and algorithm version. **Do not summarise favourably.** A protocol
whose conclusion is "the hardware premise does not hold well enough to make any
detection claim" is a successful use of this document.

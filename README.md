# WallField

An experimental AR magnetic-field anomaly mapper for walls, for iPhone.

WallField reads the iPhone's magnetometer through Core Motion, recognises a
vertical wall with ARKit, and maps statistically significant changes in the local
magnetic field onto that wall as an augmented-reality heat map.

**WallField does not image through walls.** It cannot tell you what caused a
reading, whether wiring is present or carrying current, or how deep anything is;
it is not an electrical safety device; and a quiet reading is never evidence that
a location is safe to drill. See
[`Docs/SAFETY_AND_LIMITATIONS.md`](Docs/SAFETY_AND_LIMITATIONS.md).

> WallField measures local magnetic-field changes using the iPhone's sensors. It
> cannot identify every hidden object, determine whether wiring is present or
> energized, measure object depth, or confirm that a location is safe to drill.
> Use certified detection equipment and appropriate professional guidance before
> drilling.

---

## Status

The application is complete and the algorithm is verified against synthetic
data. **The detection thresholds are provisional and have not yet been measured
against known physical ground truth**, which is why `AlgorithmVersion.current`
carries a `-provisional` suffix and the app says so in Diagnostics and on every
saved scan. [`Docs/VALIDATION_PROTOCOL.md`](Docs/VALIDATION_PROTOCOL.md) defines
the experiments that have to be run on real hardware before that suffix comes
off or any detection claim is made.

## Requirements

| | |
|---|---|
| Xcode | 16.0 or newer (the project uses `objectVersion = 77` file-system-synchronized groups) |
| Swift | 6.0, strict concurrency `complete` |
| Deployment target | iOS 18.0, iPhone only |
| Dependencies | None. Apple frameworks only |
| Device | **A physical iPhone is required for real measurements.** ARKit world tracking and the magnetometer do not exist in the Simulator |

## Opening and running

```sh
open WallField.xcodeproj
```

Two shared schemes:

* **WallField** — the normal app. Run it on a physical iPhone.
* **WallField (Simulated Data)** — runs the whole app against a deterministic
  synthetic wall and sensor, so the entire flow works in the Simulator. Every
  screen it drives is labelled *Simulated data*, and it is compiled out of
  Release builds entirely.

### Signing

No Apple Team ID or certificate is committed. Either pick your team in
Xcode under **WallField → Signing & Capabilities**, or create a git-ignored
`Config/Signing.local.xcconfig`:

```
DEVELOPMENT_TEAM = YOURTEAMID
PRODUCT_BUNDLE_IDENTIFIER = com.yourcompany.wallfield
```

## Using the app

1. **Onboarding** explains what is and is not measured, and asks you to accept a
   specific statement of the limitation. The accepted version and date are stored
   so revised wording is shown again after an update.
2. **Preparation checklist** — remove MagSafe wallets, magnetic mounts and
   magnetic cases; move chargers, speakers and loose metal away. Magnets near the
   phone are by far the biggest cause of misleading readings. No hardware starts
   until you leave this screen.
3. **Map the wall.** ARKit shades detected vertical planes blue. Put the
   crosshair on the one you want and lock it. Locking prevents readings drifting
   between surfaces mid-scan.
4. **Calibrate.** Hold the phone still for a few seconds. WallField measures the
   quiet field where you are standing and how much it naturally wobbles.
   Everything after this is relative to that, because no fixed absolute number
   means "metal".
5. **Scan.** Move slowly and steadily, roughly a hand's width per second, with
   the crosshair on the locked wall. Marks appear where the field changes more
   than the local noise can explain.
6. **Repeat a pass.** Tap *New pass* and cover the same area again. A reading
   measured once stays **Unconfirmed** however large it is; one measured again in
   the same place on a later pass becomes **Repeated**.
7. **Review and save.** You get a flat 2D map of the wall, the numbers behind
   every mark, the scan-quality summary, and CSV + JSON export.

## Testing

```sh
xcodebuild test \
  -project WallField.xcodeproj \
  -scheme WallField \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

* `WallFieldTests` — unit tests for the pure logic: statistics, calibration,
  detection, geometry, timestamp matching, quality gating, clustering,
  persistence, export, preferences and safety copy.
* `WallFieldUITests` — end-to-end flows driven by simulated data.

## Repository checks

These run anywhere Python 3 is available, including on a machine with no Xcode:

```sh
Tools/check_all.sh                    # all of the below
```

```sh
python3 Tools/validate_project.py     # Xcode project reference integrity
python3 Tools/audit_sources.py        # Swift source rules
python3 Tools/check_symbols.py        # every Namespace.member reference resolves
python3 Tools/lint_claims.py          # prohibited and guarded wording
python3 Tools/verify_algorithm.py     # detection arithmetic vs the test expectations
python3 Tools/validate_workflows.py   # CI config vs the real schemes, bundle id and code
python3 Tools/select_simulator.py --self-test
```

`Tools/verify_algorithm.py` is a Python port of the detector used to check the
*algorithm* and the expectations the XCTests assert. It is not a substitute for
running the XCTest suite: it does not compile Swift and cannot catch a Swift
error. See the header of `Tools/detector_reference.py`.

`Tools/validate_workflows.py` needs PyYAML (`pip3 install pyyaml`); everything
else uses the standard library only.

Two files are generated and can be rebuilt from source:

```sh
python3 Tools/generate_xcodeproj.py   # rewrites WallField.xcodeproj
python3 Tools/generate_app_icon.py    # rewrites the 1024pt app icon
```

## Continuous integration

Two GitHub Actions workflows, in `.github/workflows/`.

| Workflow | Trigger | What it does |
|---|---|---|
| `tests.yml` | every push and pull request | Runs `Tools/check_all.sh` on Linux first, so a rule violation fails the run before a macOS runner is claimed. Then selects an Xcode of at least 26 with the iOS 26 SDK, compiles the app for a **discovered** iOS Simulator, and builds and runs every unit and UI test. Signs nothing, uploads nothing, and **uses no secrets at all** — the repository is public, so pull requests from forks run this, and a workflow that needs no secret cannot leak one. |
| `testflight.yml` | `workflow_dispatch` only | Checks every required secret is present, calls `tests.yml` (rather than copying it, so the two cannot drift), then chooses a build number, imports signing material into a throwaway keychain, archives Release, exports a normal App Store IPA, verifies the shipped `Info.plist`, validates with App Store Connect as a free dry run, and uploads to TestFlight. |

Neither the runner's Xcode nor the simulator is named in the configuration.
`Tools/select_xcode.sh` picks the newest installed Xcode that meets the floor,
and `Tools/select_simulator.py` picks the newest available iPhone on the newest
available iOS runtime, so a change to the runner image cannot silently break the
build — and both fail with a list of what the machine actually has.

### Releasing

`testflight.yml` is manual: no push, tag or merge can ship a build. Before the
first run, add these under **Settings → Secrets and variables → Actions**:

| Secret | What it is |
|---|---|
| `APPLE_DISTRIBUTION_CERTIFICATE` | base64 of the Apple Distribution `.p12` |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | the password used when exporting it |
| `APPLE_PROVISIONING_PROFILE` | base64 of the App Store `.mobileprovision` |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | contents of the `AuthKey_*.p8`, including its BEGIN/END lines |

The preflight job names every one that is missing, so a misconfiguration costs
one fast job rather than an hour of building. `CFBundleVersion` is the workflow
run number plus the optional `BUILD_NUMBER_OFFSET` repository variable, which
exists for the case where builds already in App Store Connect were uploaded by
something else; a run can also be given an explicit build number.

The release workflow deliberately does **not** pass
`testFlightInternalTestingOnly`, and asserts it is absent from the generated
export options before archiving, so the uploaded build stays eligible for App
Store submission. It also verifies the shipped `Info.plist` before uploading:
bundle identifier, build number, and that `ITSAppUsesNonExemptEncryption` is
present and `false`. Signing material lives in a keychain created for the job
and destroyed in a step that runs even when an earlier one failed.

## Layout

```text
WallField/
  App/            composition root, entry point
  Models/         value types: samples, calibration, candidates, clusters, scans
  Detection/      robust statistics, calibration engine, online detector
  SpatialMapping/ wall coordinate frame, pose buffer, quality gate, clustering
  Sensors/        Core Motion service, simulated environment and sensor
  AR/             ARKit session controller, RealityKit rendering, simulated provider
  Persistence/    versioned local store, preferences, CSV and JSON export
  DesignSystem/   palette, theme, shared components, feedback
  Features/       Onboarding, Home, Scanner, Review, History, Diagnostics, Settings
  Copy/           branding and every safety string, in one reviewable place
  Utilities/      logging, clock, formatting, capabilities, throttling
Config/           xcconfig build settings, Info.plist, signing (no Team ID)
Docs/             architecture, algorithm, safety, validation, App Store, privacy
Tools/            project generator, icon generator, and the repository checks
.github/workflows/  tests on every push; TestFlight release by hand
```

## Privacy

Version 1 is entirely on-device: no account, no analytics SDK, no advertising
SDK, no cloud upload, no location, no microphone, no contacts or photo library,
and no tracking. Scans are stored in Application Support and leave the device
only when you export and share them yourself. See
[`Docs/PRIVACY.md`](Docs/PRIVACY.md).

## Documentation

* [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) — modules, data flow, coordinate
  systems, time basis, threading and lifecycle
* [`Docs/ALGORITHM.md`](Docs/ALGORITHM.md) — calibration, median/MAD, thresholds,
  synchronisation, clustering and what confidence means
* [`Docs/SAFETY_AND_LIMITATIONS.md`](Docs/SAFETY_AND_LIMITATIONS.md) — the
  scientific and user-safety limits, and the rules the product enforces
* [`Docs/VALIDATION_PROTOCOL.md`](Docs/VALIDATION_PROTOCOL.md) — the physical
  test plan and the evidence required before release
* [`Docs/APP_STORE_PREP.md`](Docs/APP_STORE_PREP.md) — permissions, privacy
  answers, review notes, prohibited claims, screenshots and remaining items
* [`Docs/PRIVACY.md`](Docs/PRIVACY.md) — the privacy statement

---

WallField is a product of Idlery Services LLC.

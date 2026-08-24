# App Store preparation

Everything needed to submit WallField, and an honest list of what is still
outstanding. Items marked **BLOCKING** cannot be resolved from inside this
repository.

---

## 1. Outstanding items

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Apple Team ID and signing certificate | Idlery Services LLC | **BLOCKING** — never commit these; see `Config/Signing.xcconfig` |
| 2 | App Store Connect **app record** created for `com.idlery.magshift` | Idlery Services LLC | **BLOCKING** — automatic signing registers the Bundle ID in the Developer Portal but cannot create the app record; without one the upload fails with "No suitable application records were found". See [`RELEASE_TO_TESTFLIGHT.md`](RELEASE_TO_TESTFLIGHT.md) §1.2 |
| 3 | Published support URL | Idlery Services LLC | **BLOCKING** — `Branding.supportURL` is deliberately `nil`, and Settings hides the row rather than shipping a dead control |
| 4 | Published privacy-policy URL | Idlery Services LLC | **BLOCKING** — same, `Branding.privacyPolicyURL`; content is in `Docs/PRIVACY.md` |
| 5 | Physical-device validation | Engineering | **BLOCKING** — `Docs/VALIDATION_PROTOCOL.md` §8 is entirely unperformed |
| 6 | Threshold validation before any detection claim | Engineering | **BLOCKING** — see `VALIDATION_PROTOCOL.md` §7 |
| 7 | Screenshots from a real device | Design | Required; see §6 |
| 8 | App icon | Design | A generated icon ships at `WallField/Resources/Assets.xcassets/AppIcon.appiconset`. Replace it if Idlery has brand artwork |
| 9 | Distribution certificate, provisioning profile and App Store Connect API key, as eight GitHub repository secrets | Idlery Services LLC | **BLOCKING for CI** — see [`RELEASE_TO_TESTFLIGHT.md`](RELEASE_TO_TESTFLIGHT.md) §1–§2 |
| 10 | Codemagic App Store Connect integration name | Idlery Services LLC | Only if the Codemagic fallback is used — `integrations.app_store_connect` in `codemagic.yaml` must match the integration name in Codemagic → Integrations |

## 2. Build configuration

| Setting | Value | Where |
|---|---|---|
| Deployment target | iOS 18.0 | `Config/Shared.xcconfig` |
| Device family | iPhone only (`TARGETED_DEVICE_FAMILY = 1`) | `Config/Shared.xcconfig` |
| Swift | 6.0, strict concurrency `complete` | `Config/Shared.xcconfig` |
| Orientation | Portrait only | `Config/WallField-Info.plist` |
| Marketing version | `1.0.0` | `Config/Shared.xcconfig` |
| Build number | `1` | `Config/Shared.xcconfig` |
| Encryption | `ITSAppUsesNonExemptEncryption = false` | `Config/WallField-Info.plist` |

A Release build cannot select simulated data: `RuntimeMode.resolve()` returns
`.live` unconditionally under `#if !DEBUG`, the Settings toggle that would change
it is behind `RuntimeMode.developerToolsAvailable` (also `#if DEBUG`), and the
`-WallFieldDemoMode` launch argument is ignored. There is therefore no path by
which synthetic readings could reach a reviewer or a user. The synthetic types
themselves are ordinary Swift and are still compiled; what is removed is every
way of reaching them.

## 3. Permissions and capabilities

```xml
<key>NSCameraUsageDescription</key>
<string>WallField uses the camera to recognize a wall and place magnetic-field visualizations in augmented reality.</string>
<key>NSMotionUsageDescription</key>
<string>WallField uses motion sensors to measure changes in the local magnetic field during a scan.</string>

<key>UIRequiredDeviceCapabilities</key>
<array>
    <string>arkit</string>
    <string>magnetometer</string>
</array>
```

`UIRequiredDeviceCapabilities` is set because the app's core function is
impossible without both. This restricts App Store availability to devices that
have them, which is the honest outcome.

The app still handles denial and unavailability gracefully rather than assuming
the capability keys guarantee anything: camera denial and restriction are
explained with a route to Settings where one exists, an unsupported device is
explained and offers Diagnostics instead, and a missing magnetometer is reported
rather than crashed on.

## 3a. Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in `Config/WallField-Info.plist`, and
that is **accurate for this code**, not an assumption:

* the app imports only ARKit, AVFoundation, AudioToolbox, Charts, Combine,
  CoreMotion, Foundation, Observation, RealityKit, SwiftUI, UIKit, `os` and
  `simd` — no CryptoKit, no CommonCrypto, no Security, no Network;
* there is no `URLSession`, no socket, no web view, and no network call of any
  kind, so there is no HTTPS to declare;
* there are no entitlements files, so no keychain sharing or app groups;
* scans are written as plain JSON. The only encryption involved is iOS's own
  Data Protection at rest, which is exempt.

`Tools/validate_codemagic.py` re-checks all of that on every run: it fails if
the key is missing or true, if any encryption or networking framework is
imported, or if an entitlements file appears. The release workflow additionally
unzips the built IPA and asserts the key survived into the shipped `Info.plist`,
so the compliance question cannot stall a TestFlight upload.

Answer "No" to the export-compliance question in App Store Connect on the
strength of the above.

## 4. App Privacy answers

| Question | Answer |
|---|---|
| Does your app collect data? | **No** |
| Data linked to the user | None |
| Data used to track the user | None |
| Third-party SDKs | None |

This is accurate for the implementation as it stands. `Docs/PRIVACY.md` is the
detailed statement. **If any future version adds analytics, crash reporting,
cloud sync or any network transmission, these answers must change in the same
release.**

## 5. Metadata

### Name and subtitle

* Name: **WallField**
* Subtitle: *Map magnetic changes on a wall*

### Category

Utilities. Do **not** categorise as a safety or medical app.

### Promotional text and description

Acceptable wording (from the product requirements):

* "Visualize changes in the magnetic field around your iPhone."
* "Map repeatable magnetic anomalies onto a detected wall."
* "Experimental measurement aid."
* "Results vary by device, environment, material, distance, and scan technique."

Prohibited wording, in the listing, screenshots, promotional text, release notes
and support content alike:

<!-- lint-allow-banned-phrase: begin -- this list is the prohibition itself. -->
* "X-ray wall scanner."
* "See through drywall."
* "Find live wires."
* "Know where it is safe to drill."
* "Detect every screw, pipe, stud, or cable."
* "Professional-grade safety detector."
<!-- lint-allow-banned-phrase: end -->

`Tools/lint_claims.py` enforces this across the repository. Run it before
preparing any listing copy, and paste draft copy into a file it scans if in
doubt.

### The paragraph that must appear prominently

In the description, in onboarding, on the scan screen, on saved results, in
support content and in the review notes:

> WallField measures local magnetic-field changes using the iPhone's sensors. It
> cannot identify every hidden object, determine whether wiring is present or
> energized, measure object depth, or confirm that a location is safe to drill.
> Use certified detection equipment and appropriate professional guidance before
> drilling.

### Age rating

No objectionable content. Answer the questionnaire honestly; nothing in the app
warrants a raised rating.

### Monetisation

**None in this build.** No subscriptions, no in-app purchases. Establish that the
core measurement experience works on real devices before monetisation adds review
and testing complexity.

## 6. Screenshots

Required device sizes per current App Store Connect rules. Every screenshot must
be taken from a **real device with real data** — never from the simulated-data
mode, and never composited to show marks that were not measured.

Suggested set:

1. Home, showing the experimental reminder.
2. Wall mapping, with the blue plane overlay and the crosshair.
3. Calibration in progress.
4. Active scan, showing the live field readout and at least one mark.
5. Review, showing the 2D wall map, the legend and the limitation statement.
6. The Safety & limitations page.

If a caption is overlaid on a screenshot it is marketing copy and the same
prohibited-wording rules apply.

## 7. App Review notes

Paste this into the review notes field:

> WallField is an experimental AR magnetic-field anomaly mapper for walls.
>
> WallField measures local magnetic-field changes using the iPhone's sensors. It
> cannot identify every hidden object, determine whether wiring is present or
> energized, measure object depth, or confirm that a location is safe to drill.
> Use certified detection equipment and appropriate professional guidance before
> drilling.
>
> The app makes no safety claim. It never labels a reading as a wire, screw,
> stud, pipe or cable — every detected feature is labelled "Magnetic anomaly" —
> and it never presents any state as safe or clear. A quiet result reads "No
> strong anomaly measured", always followed by "This does not mean the area is
> safe to drill."
>
> Onboarding requires the user to accept that limitation explicitly before the
> app can be used, and a permanently accessible Safety & limitations page is
> reachable from Settings, from the home screen, from the scan screen and from
> every saved scan.
>
> **Testing on a device:** the app needs a physical iPhone. ARKit world tracking
> and the magnetometer do not exist in the Simulator. Point the camera at a wall
> in good light, wait for the blue overlay, tap "Lock this wall", tap
> "Calibrate" and hold the phone still for about three seconds, then tap "Start
> scan" and move the phone slowly across the wall. Passing over a screw, a nail
> or a steel stud plate should produce a mark.
>
> Everything is on-device: no account, no analytics, no advertising, no network
> connection. The two permissions requested are camera (for ARKit wall
> recognition) and motion (for magnetic-field readings).
>
> The simulated-data mode used for development cannot be selected in this
> build: the runtime mode resolves to live unconditionally in a Release build,
> and the developer toggle that would switch it is compiled out.

## 8. Guideline notes

* **2.1 App Completeness.** No placeholder screens, no TODO stubs, no dead
  controls. Controls that would be dead — a support link with no URL — are hidden
  rather than shipped.
* **2.5.4 / device resource use.** The idle timer is disabled only while actively
  measuring. Expensive render features are off. Scene depth is not enabled. All
  buffers are bounded.
* **1.4 Physical Harm.** The app makes no safety claim, provides no clearance to
  drill, and repeatedly states that absence of a reading is not evidence of
  safety. It never asks a user to open electrical equipment or work near exposed
  conductors.
* **5.1.1 Data Collection and Storage.** Two permissions, both with specific
  purpose strings, both essential to the function requested.
* **2.3 Accurate Metadata.** The prohibited-wording list above exists to satisfy
  this, and is enforced by a repository check.

## 9. Continuous integration

Two manually triggered GitHub Actions workflows, in `.github/workflows/`:

* **Checks and Simulator tests** — toolchain guard, `Tools/check_all.sh`,
  compile for a discovered iOS Simulator, and the full unit and UI test suite.
  Code signing is disabled and nothing is uploaded.
* **TestFlight release** — runs the above as its `verify` job, then produces a
  signed App Store archive and uploads it to App Store Connect and TestFlight.
  It cannot sign or upload unless verification passed.

Points that matter for review and for the store:

* Neither workflow can be started by a push. Both are `workflow_dispatch` only.
* Neither the Xcode version nor the Simulator is pinned. The build fails, loudly
  and early, unless Xcode is at least 26.4 **and** the newest installed iOS SDK
  is at least 26.0, which is what Apple requires of uploads made since 28 April
  2026.
* The release build is an ordinary App Store export.
  `testFlightInternalTestingOnly` is never written, and a dedicated step fails
  the build if it appears in the generated export options — an internal-only
  build could never be submitted to the App Store, which would defeat the point
  of building it.
* The build number is taken from what App Store Connect already holds, so a
  build uploaded from anywhere else cannot cause a collision. It is applied with
  a command-line `CURRENT_PROJECT_VERSION`, and `manageAppVersionAndBuildNumber`
  is false, so the CI never mutates the repository to change a version and Xcode
  never renumbers it during export.
* The shipped `Info.plist` is re-opened and checked before the upload: bundle
  identifier, build number, and `ITSAppUsesNonExemptEncryption = false`.
* Signing material is imported into a throwaway keychain and deleted again even
  when an earlier step fails.
* Submitting for App Store review is a separate, deliberate decision that the
  workflow does not make, and `Docs/VALIDATION_PROTOCOL.md` has to be completed
  first.

`codemagic.yaml` defines the same two workflows for Codemagic and is kept as a
fallback. Both must not run against the same app at once.

**No CI build has been run yet.** Until one has, the Swift project is unproven:
it has never been compiled, and no XCTest has ever executed.

The step-by-step release procedure, its Apple-side prerequisites and a table of
what each failure means are in
[`RELEASE_TO_TESTFLIGHT.md`](RELEASE_TO_TESTFLIGHT.md).

## 10. Pre-submission checklist

- [ ] `Tools/check_all.sh` passes
- [ ] **Checks and Simulator tests** passes on GitHub Actions — this is the
      first proof the project compiles at all
- [ ] **TestFlight release** produces an IPA and uploads it
- [ ] The uploaded build appears in TestFlight and is installable
- [ ] `Docs/VALIDATION_PROTOCOL.md` §8 completed on a real device, with results
      written down
- [ ] `Docs/VALIDATION_PROTOCOL.md` §7 answered from measured data, or all
      detection claims removed from the listing
- [ ] Support and privacy URLs published and set in `Branding`
- [ ] Screenshots taken from a real device with real data
- [ ] Listing copy checked against §5, including screenshot captions
- [ ] App Privacy answers match `Docs/PRIVACY.md`
- [ ] Review notes pasted from §7

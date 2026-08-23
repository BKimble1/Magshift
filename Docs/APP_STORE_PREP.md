# App Store preparation

Everything needed to submit WallField, and an honest list of what is still
outstanding. Items marked **BLOCKING** cannot be resolved from inside this
repository.

---

## 1. Outstanding items

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Apple Team ID and signing certificate | Idlery Services LLC | **BLOCKING** — never commit these; see `Config/Signing.xcconfig` |
| 2 | Bundle identifier registered in App Store Connect | Idlery Services LLC | **BLOCKING** — `com.idlery.wallfield` is a suggestion |
| 3 | Published support URL | Idlery Services LLC | **BLOCKING** — `Branding.supportURL` is deliberately `nil`, and Settings hides the row rather than shipping a dead control |
| 4 | Published privacy-policy URL | Idlery Services LLC | **BLOCKING** — same, `Branding.privacyPolicyURL`; content is in `Docs/PRIVACY.md` |
| 5 | Physical-device validation | Engineering | **BLOCKING** — `Docs/VALIDATION_PROTOCOL.md` §8 is entirely unperformed |
| 6 | Threshold validation before any detection claim | Engineering | **BLOCKING** — see `VALIDATION_PROTOCOL.md` §7 |
| 7 | Screenshots from a real device | Design | Required; see §6 |
| 8 | App icon | Design | A generated icon ships at `WallField/Resources/Assets.xcassets/AppIcon.appiconset`. Replace it if Idlery has brand artwork |

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

Release builds compile simulated data out entirely (`RuntimeMode.resolve()`
returns `.live` unconditionally under `#if !DEBUG`), so there is no path by which
synthetic readings could reach a reviewer or a user.

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
> There is no simulated-data mode in this build; it is compiled out of Release
> builds entirely.

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

## 9. Pre-submission checklist

- [ ] `Tools/check_all.sh` passes
- [ ] `xcodebuild test` passes on a Simulator, with no new warnings
- [ ] `xcodebuild build` for a physical device succeeds with signing configured
- [ ] `Docs/VALIDATION_PROTOCOL.md` §8 completed on a real device, with results
      written down
- [ ] `Docs/VALIDATION_PROTOCOL.md` §7 answered from measured data, or all
      detection claims removed from the listing
- [ ] Support and privacy URLs published and set in `Branding`
- [ ] Screenshots taken from a real device with real data
- [ ] Listing copy checked against §5, including screenshot captions
- [ ] App Privacy answers match `Docs/PRIVACY.md`
- [ ] Review notes pasted from §7

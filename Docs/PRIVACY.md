# Privacy

WallField version 1 is entirely on-device.

## What WallField does not do

* No account, sign-in or user identifier.
* No analytics SDK.
* No advertising SDK, and no advertising identifier is requested.
* No cloud upload, no server, and no network connection of any kind.
* No location data.
* No microphone access.
* No contacts, calendar or photo-library access.
* No tracking, in the App Tracking Transparency sense or any other.

The app requests exactly two permissions, both essential to the function the user
just asked for:

| Permission | Why |
|---|---|
| **Camera** (`NSCameraUsageDescription`) | ARKit needs the camera to recognise a wall and place magnetic-field visualizations on it. Camera frames are used for tracking and shown live on screen. No frame is recorded, stored, or included in any export. |
| **Motion** (`NSMotionUsageDescription`) | Core Motion provides the magnetic-field readings that are the app's whole purpose. |

## What is stored, and where

Saved scans live in the app's own `Application Support/WallField/Scans` folder as
one JSON file per scan. Nothing else is written outside the app container. The
folder is not exposed in the Files app: `UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace` are both false.

A saved scan contains:

* the name, notes and validation tags the user typed;
* dates, duration and the pass count;
* the app version and algorithm version;
* the exact detector configuration and calibration summary;
* the locked wall's coordinate metadata;
* each accepted measurement — field vector, magnitude, delta, score, calibration
  accuracy, timing error, tracking state, raycast quality and wall position;
* the merged clusters and the scan-quality summary;
* **device metadata**: hardware model identifier (e.g. `iPhone16,1`), OS version,
  and whether the device supports scene depth.

The hardware model identifier is shared by every unit of that model. It describes
hardware, not a person or a device, and it is stored because comparing sensor
behaviour across iPhone models is a stated requirement of the validation work.
`identifierForVendor` is not read. No advertising identifier is requested.

Preferences — sensitivity, haptics, sound, overlay visibility, and the safety
acknowledgement version and date — are stored in `UserDefaults`.

## Logging

Log output is deliberately restrained and privacy-safe. Only lifecycle
transitions and error conditions are logged. No measurement value, file path,
scan name or user note is ever written to the log, so a sysdiagnose taken from a
user's device cannot leak the contents of their scans.

## Sharing

Scans leave the device only when the user exports one and chooses where to send
it, through the standard iOS share sheet. Exported files are written to a
per-export temporary directory that is deleted when the share sheet closes.

Exported files contain everything listed above, plus the safety limitation
statement in their header, so the limitation travels with the data.

## Deletion

Deleting a scan deletes its file. Deleting all scans, from Settings, deletes the
whole folder's contents. Deleting the app removes everything, as with any iOS
app. Nothing is retained anywhere else, because nothing is sent anywhere else.

## App Privacy answers

For the App Store "App Privacy" questionnaire, based on the implementation as it
stands:

| Question | Answer |
|---|---|
| Does your app collect data? | **No** |
| Data linked to the user | None |
| Data used to track the user | None |
| Third-party SDKs | None |

"No data collected" is accurate **only while the above remains true**. If any
future version adds analytics, crash reporting, cloud sync or any network
transmission, these answers and this document must be updated in the same change.
There is a corresponding item in `APP_STORE_PREP.md`.

## Encryption

`ITSAppUsesNonExemptEncryption` is `false` in `Config/WallField-Info.plist`. The
app performs no encryption and makes no network connections.

---

Idlery Services LLC. A published privacy-policy URL is required before
submission; see `Docs/APP_STORE_PREP.md`.

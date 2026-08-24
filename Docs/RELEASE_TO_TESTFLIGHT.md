# Releasing to TestFlight

The exact sequence that puts a build in TestFlight through **GitHub Actions**,
what has to exist before it can work, and what each failure means.

Two workflows, both started by hand from the Actions tab. Neither has a push or
tag trigger: a release is a decision, not a side effect of merging.

| Workflow | File | What it does |
|---|---|---|
| **Checks and Simulator tests** | `.github/workflows/tests.yml` | Toolchain guard, `Tools/check_all.sh`, compiles the app for a discovered Simulator, builds both test bundles, runs every unit and UI test. Signs nothing, uploads nothing, needs no Apple account. |
| **TestFlight release** | `.github/workflows/testflight.yml` | Runs the whole of the above first, then chooses a build number, signs, archives, exports an App Store IPA, verifies the shipped `Info.plist`, and uploads to App Store Connect and TestFlight. |

The release workflow calls the test workflow as its `verify` job and will not
sign or upload unless it passes, so a release can never be the first thing that
compiled this project.

---

## 0. What cannot be done from this repository

Uploading to TestFlight needs an Apple Developer account, a distribution
certificate and an App Store Connect API key. None of those live here, and none
of them should. Sections 1 and 2 have to be performed by someone signed in to
Idlery Services LLC's Apple account.

## 1. Apple side, once

### 1.1 Create the App Store Connect app record

**App Store Connect → Apps → + → New App.** Platform **iOS**, bundle ID
`com.idlery.magshift`, any SKU, and a name not already taken on the App Store.

This is the step most often missed, and it fails only at the very end of an
otherwise successful build:

```
No suitable application records were found.
```

Registering the Bundle ID in the Developer Portal is a *different* thing and is
not enough. The name is metadata and can be changed later; it does not have to
match the name inside the app.

### 1.2 Create an App Store Connect API key

**App Store Connect → Users and Access → Integrations → App Store Connect API →
+.** Give it the **App Manager** role. Keep three things:

* the **Issuer ID** shown above the table,
* the **Key ID**,
* the **`AuthKey_<KeyID>.p8`** file — Apple lets you download it exactly once.

### 1.3 Create the distribution certificate

In Xcode: **Settings → Accounts → your Apple ID → Manage Certificates → + →
Apple Distribution**. Then in **Keychain Access**, find that certificate, expand
it so the private key is included, right-click → **Export**, save as
`.p12`, and **set a password** — the workflow requires one.

If a distribution certificate already exists on a colleague's machine, export it
from there instead. Apple allows only three at a time.

### 1.4 Create the App Store provisioning profile

**developer.apple.com → Certificates, Identifiers & Profiles → Profiles → +**,
choose **App Store Connect** under Distribution, select the App ID for
`com.idlery.magshift`, select the certificate from 1.3, name it, and download
the `.mobileprovision`.

The workflow reads the profile's name out of the file itself, so the name you
choose does not have to be recorded anywhere.

## 2. GitHub side, once

Add eight **repository secrets** under **Settings → Secrets and variables →
Actions → New repository secret**.

| Secret | What to put in it |
|---|---|
| `APPLE_TEAM_ID` | Your ten-character Team ID, from developer.apple.com → Membership |
| `BUILD_CERTIFICATE_BASE64` | The `.p12` from 1.3, base64-encoded |
| `P12_PASSWORD` | The password you set when exporting that `.p12` |
| `PROVISIONING_PROFILE_BASE64` | The `.mobileprovision` from 1.4, base64-encoded |
| `KEYCHAIN_PASSWORD` | Any password you invent. It only protects the throwaway keychain the job creates and deletes |
| `APP_STORE_CONNECT_KEY_ID` | The Key ID from 1.2 |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID from 1.2 |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The **entire contents** of the `.p8` file, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |

To base64-encode the two files, on a Mac:

```sh
base64 -i Certificates.p12 | pbcopy          # then paste into the secret
base64 -i WallField_AppStore.mobileprovision | pbcopy
```

For the `.p8`, paste the file itself — `cat AuthKey_XXXXXXXX.p8 | pbcopy` — not
base64.

The first step of the release job names any secret that is missing, so a typo in
a secret name costs seconds rather than a whole build.

**Nothing else needs configuring.** The workflows discover the Xcode version and
the Simulator on the runner rather than pinning either, so a change to the runner
image cannot silently break the build.

## 3. Prove it builds first

**Actions → Checks and Simulator tests → Run workflow.**

Run this before the release workflow, at least the first time. It is the only
thing that proves the Swift compiles and the tests pass, and it needs no secrets
and no Apple account, so it can be run by anyone at any time.

The `runner` input defaults to `macos-latest`. If the toolchain guard fails
because the image's Xcode is too old, re-run with a newer label (`macos-26`).

Artifacts: the `.xcresult` bundle and every build log.

## 4. Release

**Actions → TestFlight release → Run workflow.**

The `verify` job runs first — the whole of §3. Only if it passes does the
`release` job:

1. check all eight secrets are present, and fail immediately if any is missing;
2. select an Xcode meeting the floor and confirm the iOS SDK is new enough;
3. install the API key, and reject a `.p8` secret that is not a `.p8`;
4. ask App Store Connect for the highest build number it already holds and take
   one past it, or the run number, whichever is higher;
5. import the certificate into a throwaway keychain, install the profile, and
   **check the profile is actually for `com.idlery.magshift`** before building;
6. write the export options and assert `testFlightInternalTestingOnly` is not
   among them, so the build stays eligible for App Store submission later;
7. archive Release for a generic iOS device with the chosen build number;
8. export a normal App Store IPA;
9. re-open the shipped `Info.plist` and verify the bundle identifier, the build
   number, and that `ITSAppUsesNonExemptEncryption` is present and `false`;
10. upload to App Store Connect and TestFlight;
11. delete the keychain, the certificate, the profile and the key — even if an
    earlier step failed.

Expect roughly 40–70 minutes across both jobs, most of it the test suite.
Artifacts: the IPA, the dSYMs and every log.

## 5. After the upload

* The build appears under **App Store Connect → your app → TestFlight → iOS
  builds**, in *Processing*, for a few minutes.
* There is no export-compliance question to answer: the shipped `Info.plist`
  declares `ITSAppUsesNonExemptEncryption = false`, and step 9 above fails the
  build if that ever stops being true.
* **Internal testers** — up to 100 people holding a role on the App Store
  Connect team — can install as soon as processing finishes. No review.
* **External testers** need a beta group and Apple's Beta App Review. Create the
  group in App Store Connect and add the build to it there.
* Testers install through the TestFlight app. The build carries the marketing
  version from `Config/Shared.xcconfig` (`1.0.0`) and the CI-assigned build
  number.

TestFlight is as far as this repository is meant to go for now. Submitting for
App Store review is a separate decision, and `Docs/VALIDATION_PROTOCOL.md` has to
be completed first — the detection thresholds have never been measured against
physical ground truth, which is why `AlgorithmVersion.current` still carries its
`-provisional` suffix.

## 6. When a run fails

| What you see | What it means | Fix |
|---|---|---|
| `missing repository secrets: …` | Exactly what it says, naming each one | §2 |
| `no installed Xcode meets the required minimum` | The runner image's newest Xcode is below the floor | Re-run with a newer `runner` label |
| `the newest installed iOS SDK is …` | The image predates the iOS 26 SDK Apple requires for uploads | Re-run with a newer `runner` label |
| A `Tools/…` check fails | A repository rule was broken | Reproduce locally with `Tools/check_all.sh` |
| A test fails | A real failure — the suite is deterministic and runs with parallel testing off | Read the `.xcresult` artifact |
| `APP_STORE_CONNECT_PRIVATE_KEY does not look like a .p8 key` | The secret holds the Key ID, or the key body without its `BEGIN`/`END` lines | §2, last row |
| `the provisioning profile is for X, but this app is com.idlery.magshift` | `PROVISIONING_PROFILE_BASE64` holds a profile for a different app | §1.4 |
| `No suitable application records were found` | The App Store Connect app record does not exist | §1.1 |
| `No signing certificate "iOS Distribution" found` | The `.p12` did not include the private key, or `P12_PASSWORD` is wrong | Re-export from Keychain Access with the key expanded (§1.3) |
| `Xcode renumbered the build` | Something set `manageAppVersionAndBuildNumber` | Should not happen; the export options set it false |
| Upload rejected for a duplicate build number | A build with that number already exists | The chooser normally prevents this; check the "Choose a build number" step's log for why the lookup fell back |
| `no IPA was produced` | The archive or export step failed above this point | Read the archive log artifact |

## 7. Codemagic, the alternative

`codemagic.yaml` defines the same two workflows for Codemagic, and still works.
It is the older path and needs a Codemagic account and an App Store Connect
integration named to match `integrations.app_store_connect`.

**Do not run both against the same app in parallel.** Two release runs would
pick a build number at the same time and the second upload would be rejected.
GitHub Actions is now the primary path; Codemagic is kept as a fallback for a
machine or account problem on GitHub's side.

## 8. Doing it locally on a Mac

With Xcode 26.4 or newer and the signing identity installed:

```sh
Tools/check_all.sh
xcodebuild test -project WallField.xcodeproj -scheme WallField \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Then **Product → Archive**, then *Distribute App → App Store Connect → Upload*.

Set your team in Xcode under **WallField → Signing & Capabilities**, or in a
git-ignored `Config/Signing.local.xcconfig`:

```
DEVELOPMENT_TEAM = YOURTEAMID
```

Do not commit a Team ID, a certificate or a provisioning profile; `.gitignore`
already excludes them.

## 9. Checklist

- [ ] App Store Connect app record exists for `com.idlery.magshift` (§1.1)
- [ ] App Store Connect API key created with the App Manager role (§1.2)
- [ ] Distribution certificate exported as a password-protected `.p12` (§1.3)
- [ ] App Store provisioning profile downloaded (§1.4)
- [ ] All eight repository secrets set (§2)
- [ ] **Checks and Simulator tests** green (§3)
- [ ] **TestFlight release** green, IPA uploaded (§4)
- [ ] Build visible in TestFlight and installable on a device (§5)
- [ ] `Docs/VALIDATION_PROTOCOL.md` §8 performed on that device

See also [`Docs/APP_STORE_PREP.md`](APP_STORE_PREP.md) for everything the public
App Store listing needs, which is a longer list than this one.

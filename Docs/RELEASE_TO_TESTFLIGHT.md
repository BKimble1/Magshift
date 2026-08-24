# Releasing to TestFlight

The exact sequence that puts a build in TestFlight, what has to exist before it
can work, and what each failure means.

Everything here runs through **Codemagic**. There is no GitHub Actions workflow
in this repository and none should be added; `codemagic.yaml` is the only CI
configuration, and both of its workflows are manual-only.

---

## 0. What cannot be done from this repository

Uploading to TestFlight needs an Apple Developer account, an App Store Connect
API key and a macOS machine with Xcode. None of those live here, and none of
them should. Steps 1 and 2 below have to be performed by someone signed in to
Idlery Services LLC's Apple and Codemagic accounts.

## 1. Apple side, once

| # | Step | Where |
|---|---|---|
| 1.1 | Apple Developer Program membership, active | developer.apple.com |
| 1.2 | **Create the app record** for `com.idlery.magshift` | App Store Connect → Apps → **+** → New App |
| 1.3 | Create an App Store Connect **API key** with the *App Manager* role, and keep the Issuer ID, Key ID and `.p8` file | App Store Connect → Users and Access → Integrations → App Store Connect API |

**1.2 is the step that is most often missed.** Codemagic's automatic signing
registers the *Bundle ID* in the Developer Portal for you, but it cannot create
the App Store Connect *app record*. Without one the upload fails at the very end
of an otherwise successful build, with:

```
No suitable application records were found.
```

When creating the record: platform **iOS**, bundle ID `com.idlery.magshift`,
any SKU, and a name that is not already taken on the App Store. The name is
metadata and can be changed later; it does not have to match `Branding.productName`.

## 2. Codemagic side, once

| # | Step | Where |
|---|---|---|
| 2.1 | Add the repository as an application | Codemagic → Add application |
| 2.2 | Add the API key from 1.3 as an **App Store Connect integration** | Codemagic → Teams/Personal account → Integrations → App Store Connect |
| 2.3 | Make the integration's name match `codemagic.yaml` | see below |
| 2.4 | *Optional:* set `APP_STORE_APPLE_ID` to the app's numeric Apple ID | Codemagic → Environment variables |

For 2.3, `codemagic.yaml` currently says:

```yaml
integrations:
  app_store_connect: WallField App Store Connect
```

Either name the integration exactly that, or edit that one line to match what
you named it. Codemagic fails the build before any script runs if the name does
not resolve, so a mismatch is loud rather than mysterious.

For 2.4, the Apple ID is the numeric value in the App Store Connect URL for the
app (`.../app/1234567890/...`). Setting it makes the build number derive from
what App Store Connect already holds, which matters if a build is ever uploaded
from outside Codemagic. Without it, Codemagic's own increasing counter is used,
which is sufficient on its own.

## 3. Prove it builds first

```
Codemagic → Start new build → workflow: wallfield-simulator-tests
```

Run this **before** the release workflow, every time. It signs nothing,
publishes nothing and needs no Apple account, and it is the only thing that
proves the Swift compiles and the tests pass. The release workflow runs the same
checks, but a failure there costs a whole signed build.

It runs, in order: the Xcode/SDK floor guard, `Tools/check_all.sh`, a compile of
the app for a discovered Simulator, a build of both test bundles, and the full
unit and UI test suite. Artifacts include the `.xcresult` bundle and every log.

**Do not start the release run until this workflow is green.**

## 4. Release

```
Codemagic → Start new build → workflow: wallfield-testflight
```

Neither workflow has a `triggering:` block, so neither can start from a push;
both are started by hand.

The release workflow repeats everything in §3, then:

1. chooses a unique, increasing build number and passes it as a command-line
   `CURRENT_PROJECT_VERSION` — the repository is never mutated to change a
   version;
2. applies the automatically fetched App Store distribution certificate and
   provisioning profile (`xcode-project use-profiles`);
3. asserts the generated export options are a normal App Store export and that
   `testFlightInternalTestingOnly` is absent, so the build stays eligible for
   App Store submission later;
4. archives and exports the IPA;
5. re-opens the shipped `Info.plist` and verifies the bundle identifier, the
   build number, and that `ITSAppUsesNonExemptEncryption` is present and
   `false`;
6. uploads to App Store Connect and TestFlight.

Expect roughly 20–40 minutes, most of it the test suite.

## 5. After the upload

* The build appears under **App Store Connect → your app → TestFlight → iOS
  builds**, in *Processing*, for a few minutes.
* There is no export-compliance question to answer: the shipped `Info.plist`
  declares `ITSAppUsesNonExemptEncryption = false`, and step 5 above fails the
  build if that ever stops being true.
* **Internal testers** — up to 100 people who hold a role on the App Store
  Connect team — can install it as soon as processing finishes. No review.
* **External testers** need a beta group and Apple's Beta App Review. To have
  Codemagic assign the build to a group automatically, add the group under
  `publishing.app_store_connect`:

  ```yaml
  publishing:
    app_store_connect:
      auth: integration
      submit_to_testflight: true
      beta_groups:
        - Your group name
  ```

* Testers install through the TestFlight app. The build carries the marketing
  version from `Config/Shared.xcconfig` (`1.0.0`) and the CI-assigned build
  number.

TestFlight is as far as this repository is meant to go for now.
`submit_to_app_store` is deliberately `false`: submitting for App Store review
is a separate decision, and `Docs/VALIDATION_PROTOCOL.md` has to be completed
first — the detection thresholds have never been measured against physical
ground truth, which is why `AlgorithmVersion.current` still carries its
`-provisional` suffix.

## 6. When a run fails

| What you see | What it means | Fix |
|---|---|---|
| Build fails instantly, before any script output | The `app_store_connect` integration name does not resolve | §2.3 |
| `No suitable application records were found` | The App Store Connect app record does not exist | §1.2 |
| `ERROR: Xcode … is older than the required …` | The image's Xcode is below the floor | Set `xcode:` to a version Codemagic offers, or `latest` |
| `ERROR: the newest installed iOS SDK is …` | The image predates the iOS 26 SDK Apple requires for uploads | Pick a newer Xcode image |
| A `Tools/…` check fails | A repository rule was broken | Reproduce locally with `Tools/check_all.sh` |
| A test fails | A real failure — the suite is deterministic and runs with parallel testing off | Read the `.xcresult` artifact |
| Signing or profile fetch fails | The API key lacks the App Manager role, or the key is not valid | §1.3 |
| `ERROR: no IPA was produced` | The archive step failed above this point | Read the archive log |
| Upload rejected for a duplicate build number | A build with that number already exists | Set `APP_STORE_APPLE_ID` (§2.4) so the number is derived from App Store Connect |

## 7. Doing it without Codemagic

On a Mac with Xcode 26.4 or newer and the signing identity installed:

```sh
# Prove it builds and passes first.
Tools/check_all.sh
xcodebuild test -project WallField.xcodeproj -scheme WallField \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Then either archive from Xcode — **Product → Archive**, then *Distribute App →
App Store Connect → Upload* — or from the command line:

```sh
xcodebuild archive \
  -project WallField.xcodeproj -scheme WallField \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/WallField.xcarchive \
  CURRENT_PROJECT_VERSION=<a number higher than any already uploaded>

xcodebuild -exportArchive \
  -archivePath build/WallField.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist <your export options plist>
```

Set your team in Xcode under **WallField → Signing & Capabilities**, or in a
git-ignored `Config/Signing.local.xcconfig`:

```
DEVELOPMENT_TEAM = YOURTEAMID
```

Do not commit a Team ID, a certificate or a provisioning profile;
`.gitignore` already excludes them.

## 8. Checklist

- [ ] App Store Connect app record exists for `com.idlery.magshift` (§1.2)
- [ ] App Store Connect API key created with the App Manager role (§1.3)
- [ ] Codemagic App Store Connect integration added and named to match (§2)
- [ ] `wallfield-simulator-tests` green (§3)
- [ ] `wallfield-testflight` green, IPA uploaded (§4)
- [ ] Build visible in TestFlight and installable on a device (§5)
- [ ] `Docs/VALIDATION_PROTOCOL.md` §8 performed on that device

See also [`Docs/APP_STORE_PREP.md`](APP_STORE_PREP.md) for everything the public
App Store listing needs, which is a longer list than this one.

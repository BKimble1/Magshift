#!/usr/bin/env python3
"""Validate the GitHub Actions workflows against what is actually in this repository.

A CI configuration is a set of claims about a project: that a scheme exists,
that a bundle identifier matches, that a build is exported one way and not
another. Those claims rot silently. This checks them:

* both workflow files parse, and the release workflow is manual-only, so no
  push, tag or merge can ship a build;
* the test workflow references no secret at all -- the repository is public, so
  pull requests from forks run it, and a workflow with no secrets cannot leak
  one;
* the release workflow calls the test workflow rather than copying it, so a
  release cannot be cut from a red tree and the two cannot drift;
* every scheme named is a *shared* scheme that really exists and carries both
  test bundles;
* the bundle identifier matches `Config/Signing.xcconfig`;
* the archive is Release, the export is a normal App Store export, and
  `testFlightInternalTestingOnly` is never enabled, so the same build stays
  eligible for App Store submission;
* the build number Xcode is given is the one the workflow chose, not one Xcode
  invented (`manageAppVersionAndBuildNumber` must be false);
* every secret the release workflow uses is one the preflight job checks for,
  and vice versa, so a missing secret fails in seconds rather than an hour in;
* the signing keychain is destroyed even when a step fails;
* no simulator is hard-coded by name -- the destination must be discovered;
* every embedded shell script parses, and `Tools/select_xcode.sh` fails the way
  it claims to when no Xcode is installed;
* the shipped `ITSAppUsesNonExemptEncryption = false` is still *true of the
  code*: no encryption or networking API is used anywhere in the app.

Run: ``python3 Tools/validate_workflows.py``
"""

from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftsource  # noqa: E402

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - reported, not raised
    print("validate_workflows.py: PyYAML is not installed. "
          "Run: python3 -m pip install pyyaml")
    raise SystemExit(1)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW_DIR = os.path.join(ROOT, ".github", "workflows")
TESTS_WORKFLOW = "tests.yml"
RELEASE_WORKFLOW = "testflight.yml"

MINIMUM_XCODE = (26, 0)
MINIMUM_IOS_SDK = (26, 0)

# Every secret the release workflow is allowed to use. Kept here as well as in
# the workflow so that adding one without documenting it fails this check.
EXPECTED_SECRETS = {
    "APPLE_DISTRIBUTION_CERTIFICATE",
    "APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD",
    "APPLE_PROVISIONING_PROFILE",
    "APPLE_TEAM_ID",
    "APP_STORE_CONNECT_KEY_ID",
    "APP_STORE_CONNECT_ISSUER_ID",
    "APP_STORE_CONNECT_PRIVATE_KEY",
}

# Frameworks and symbols that would make `ITSAppUsesNonExemptEncryption = false`
# untrue, either by performing encryption or by opening a connection that does.
ENCRYPTION_IMPORTS = {
    "CryptoKit", "CommonCrypto", "Security", "CryptoTokenKit", "LocalAuthentication",
    "Network", "CFNetwork", "WebKit", "CloudKit", "MultipeerConnectivity",
    "NetworkExtension", "SafariServices",
}
ENCRYPTION_SYMBOLS = re.compile(
    r"\b(URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWBrowser"
    r"|SecKey\w*|SecItem\w*|SecTrust\w*|kSec[A-Za-z]+|CC_\w+|CCCrypt\w*"
    r"|WKWebView|SFSafariViewController|CKContainer)\b"
)

failures: list[str] = []
checks = 0


def check(condition: bool, message: str) -> bool:
    global checks
    checks += 1
    if not condition:
        failures.append(message)
    return bool(condition)


def parse_version(text: str) -> tuple[int, ...] | None:
    if not re.fullmatch(r"\d+(\.\d+)*", str(text)):
        return None
    return tuple(int(part) for part in str(text).split("."))


# --- YAML helpers ------------------------------------------------------------


def triggers(document: dict) -> dict:
    """The `on:` block.

    YAML 1.1 reads a bare `on` as the boolean `True`, so it has to be looked up
    both ways -- which is exactly the sort of thing that silently makes a
    hand-written check pass against nothing.
    """
    for key in (True, "on"):
        if key in document:
            value = document[key]
            return value if isinstance(value, dict) else {name: None for name in value}
    return {}


def steps_of(document: dict) -> list[tuple[str, dict]]:
    """(job name, step) for every step in the document."""
    result: list[tuple[str, dict]] = []
    for job_name, job in (document.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if isinstance(step, dict):
                result.append((job_name, step))
    return result


def run_blocks(document: dict) -> list[tuple[str, str]]:
    """(step name, script) for every `run:` step."""
    return [
        (step.get("name", "<unnamed>"), step["run"])
        for _, step in steps_of(document)
        if isinstance(step.get("run"), str)
    ]


def joined_runs(document: dict) -> str:
    return "\n".join(body for _, body in run_blocks(document))


def joined_code(document: dict) -> str:
    """`joined_runs` with whole-line shell comments removed.

    A comment that *names* a forbidden flag in order to explain why it is not
    used must not read as using it.
    """
    return "\n".join(
        line for line in joined_runs(document).splitlines()
        if not line.lstrip().startswith("#")
    )


def check_runs_parse(name: str, document: dict) -> None:
    """Every `run:` block must be valid shell.

    A typo is otherwise only discovered when the job reaches that step, minutes
    in and after the runner has been paid for. `bash -n` finds it in
    milliseconds.
    """
    bash = shutil.which("bash")
    if not check(bash is not None, "bash is unavailable, so scripts cannot be syntax checked"):
        return
    for step_name, body in run_blocks(document):
        if not body.strip():
            continue
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
            handle.write(body)
            path = handle.name
        try:
            result = subprocess.run([str(bash), "-n", path], capture_output=True, text=True)
        finally:
            os.unlink(path)
        check(result.returncode == 0,
              f"{name}: step {step_name!r} is not valid shell: {result.stderr.strip()}")


# --- project facts -----------------------------------------------------------


def shared_schemes() -> dict[str, dict]:
    """Every shared scheme, by name, with the blueprint names it references."""
    schemes: dict[str, dict] = {}
    pattern = os.path.join(ROOT, "*.xcodeproj", "xcshareddata", "xcschemes", "*.xcscheme")
    for path in sorted(glob.glob(pattern)):
        name = os.path.splitext(os.path.basename(path))[0]
        root = ET.parse(path).getroot()
        testables = [
            node.find(".//BuildableReference").get("BlueprintName")
            for node in root.iter("TestableReference")
            if node.find(".//BuildableReference") is not None
        ]
        build_action = root.find("BuildAction")
        buildables = []
        if build_action is not None:
            buildables = [
                node.get("BlueprintName") for node in build_action.iter("BuildableReference")
            ]
        archive_action = root.find("ArchiveAction")
        schemes[name] = {
            "testables": testables,
            "buildables": buildables,
            "archive_configuration": (
                archive_action.get("buildConfiguration") if archive_action is not None else None
            ),
        }
    return schemes


def xcconfig_value(relative_path: str, key: str) -> str | None:
    path = os.path.join(ROOT, relative_path)
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            match = re.match(rf"^{re.escape(key)}\s*=\s*(.*)$", stripped)
            if match:
                return match.group(1).strip()
    return None


def app_swift_sources() -> list[str]:
    return sorted(glob.glob(os.path.join(ROOT, "WallField", "**", "*.swift"), recursive=True))


# --- checks ------------------------------------------------------------------


def check_common(name: str, document: dict, schemes: dict[str, dict]) -> None:
    env = document.get("env") or {}

    scheme = env.get("XCODE_SCHEME")
    if check(bool(scheme), f"{name}: declares no XCODE_SCHEME"):
        if check(scheme in schemes, f"{name}: scheme {scheme!r} is not a shared scheme"):
            testables = schemes[scheme]["testables"]
            for bundle in ("WallFieldTests", "WallFieldUITests"):
                check(bundle in testables,
                      f"{name}: scheme {scheme!r} does not run {bundle}")

    project = env.get("XCODE_PROJECT")
    if check(bool(project), f"{name}: declares no XCODE_PROJECT"):
        check(os.path.isdir(os.path.join(ROOT, str(project))),
              f"{name}: project {project!r} does not exist")

    for key, floor in (("MINIMUM_XCODE_VERSION", MINIMUM_XCODE),
                       ("MINIMUM_IOS_SDK_VERSION", MINIMUM_IOS_SDK)):
        raw = env.get(key)
        if check(raw is not None, f"{name}: declares no {key}"):
            version = parse_version(str(raw))
            check(version is not None and version >= floor,
                  f"{name}: {key} is {raw!r}, expected at least "
                  f"{'.'.join(map(str, floor))}")

    code = joined_code(document)
    # A pinned device name breaks every time the runner image changes, so the
    # destination has to be discovered.
    check("Tools/select_simulator.py" in code or "generic/platform=iOS" in code,
          f"{name}: neither discovers a simulator nor archives for a generic device")
    check(not re.search(r"-destination\s+['\"]?platform=iOS Simulator,name=", code),
          f"{name}: hard-codes a simulator by name")

    check_runs_parse(name, document)


def check_tests_workflow(document: dict) -> None:
    name = TESTS_WORKFLOW
    fired_by = triggers(document)
    for expected in ("push", "pull_request", "workflow_call"):
        check(expected in fired_by, f"{name}: is not triggered by {expected}")

    # The repository is public, so fork pull requests run this workflow. One
    # that references no secret is one that cannot leak a secret.
    used = secrets_used(TESTS_WORKFLOW)
    check(not used, f"{name}: references secrets {sorted(used)}; it must need none")

    code = joined_code(document)
    check("Tools/check_all.sh" in code, f"{name}: never runs the repository checks")
    check("-parallel-testing-enabled NO" in code,
          f"{name}: does not disable parallel testing, which the deterministic "
          "sensor tests depend on")
    check("CODE_SIGNING_ALLOWED=NO" in code,
          f"{name}: does not disable code signing for the Simulator build")
    check("test-without-building" in code, f"{name}: never runs the tests")
    for forbidden in ("altool", "--upload-app", "xcodebuild archive"):
        check(forbidden not in code,
              f"{name}: contains {forbidden!r}; this workflow reports, it does not ship")


def check_release_workflow(document: dict, bundle_id: str, schemes: dict[str, dict]) -> None:
    name = RELEASE_WORKFLOW
    fired_by = triggers(document)
    check(set(fired_by) == {"workflow_dispatch"},
          f"{name}: is triggered by {sorted(fired_by)}, expected workflow_dispatch alone "
          "so that no push or tag can ship a build")

    jobs = document.get("jobs") or {}
    check("preflight" in jobs, f"{name}: has no preflight job")

    verify = jobs.get("verify") or {}
    check(verify.get("uses") == f"./.github/workflows/{TESTS_WORKFLOW}",
          f"{name}: the verify job does not call {TESTS_WORKFLOW}; the tests must be "
          "called rather than copied so the two cannot drift")

    release = jobs.get("release") or {}
    needs = release.get("needs")
    needs = [needs] if isinstance(needs, str) else (needs or [])
    check("verify" in needs, f"{name}: the release job does not depend on verify")

    check((document.get("permissions") or {}).get("contents") == "read",
          f"{name}: does not restrict the token to contents: read")

    concurrency = document.get("concurrency") or {}
    check(concurrency.get("cancel-in-progress") is False,
          f"{name}: allows a release to be cancelled mid-flight")

    env = document.get("env") or {}
    check(env.get("BUNDLE_ID") == bundle_id,
          f"{name}: BUNDLE_ID is {env.get('BUNDLE_ID')!r} but Config/Signing.xcconfig "
          f"says {bundle_id!r}")

    scheme = env.get("XCODE_SCHEME")
    if scheme in schemes:
        check(schemes[scheme]["archive_configuration"] == "Release",
              f"{name}: scheme {scheme!r} does not archive the Release configuration")

    code = joined_code(document)
    check("-configuration Release" in code, f"{name}: does not archive Release")
    check("xcodebuild archive" in code, f"{name}: never archives")
    check("--upload-app" in code, f"{name}: never uploads")
    check("--validate-app" in code,
          f"{name}: does not validate before uploading, which is a free dry run")

    # The same build must stay eligible for App Store submission later.
    check("app-store-connect" in code or "app-store" in code,
          f"{name}: does not export with an App Store method")
    check("manageAppVersionAndBuildNumber bool false" in code,
          f"{name}: does not pin manageAppVersionAndBuildNumber to false, so Xcode "
          "may replace the chosen build number")
    enabling = re.search(r"testFlightInternalTestingOnly\s+bool\s+true", code)
    check(enabling is None,
          f"{name}: enables testFlightInternalTestingOnly, which produces a build "
          "that can never be submitted to the App Store")

    # Signing material must not outlive the job that needed it.
    cleanup = [
        step for job, step in steps_of(document)
        if "keychain" in (step.get("name") or "").lower()
        and "delete-keychain" in (step.get("run") or "")
    ]
    if check(bool(cleanup), f"{name}: never deletes the signing keychain"):
        check(cleanup[0].get("if") == "always()",
              f"{name}: the keychain is only deleted when earlier steps succeeded")

    check_release_secrets(document)


def secrets_used(filename: str) -> set[str]:
    """Secret names referenced from a GitHub expression.

    Matched inside `${{ ... }}` rather than by bare name, so that prose in a
    comment -- "this workflow uses no secrets. That is deliberate" -- is not
    mistaken for a reference.
    """
    return set(re.findall(r"\$\{\{[^}]*?secrets\.([A-Za-z0-9_]+)", read(filename)))


def check_release_secrets(document: dict) -> None:
    name = RELEASE_WORKFLOW
    used = secrets_used(RELEASE_WORKFLOW)

    check(used == EXPECTED_SECRETS,
          f"{name}: uses secrets {sorted(used)}, expected {sorted(EXPECTED_SECRETS)}. "
          "Update EXPECTED_SECRETS here and the header of the workflow together.")

    # The preflight job exists so a missing secret costs one fast job instead of
    # a full macOS build. That is only true if it checks every one of them.
    preflight = (document.get("jobs") or {}).get("preflight") or {}
    preflight_text = yaml.safe_dump(preflight)
    for secret in EXPECTED_SECRETS:
        check(secret in preflight_text,
              f"{name}: the preflight job does not check for {secret}")

    # A secret must never be echoed. `printf '%s'` into a file is fine; `echo
    # $SECRET` to the log is not.
    for step_name, body in run_blocks(document):
        for secret in EXPECTED_SECRETS:
            check(not re.search(rf"echo\s+.*\$\{{?{secret}\b", body),
                  f"{name}: step {step_name!r} echoes {secret}")


def check_repository_scripts() -> None:
    for relative in ("Tools/check_all.sh", "Tools/select_simulator.py", "Tools/select_xcode.sh"):
        path = os.path.join(ROOT, relative)
        if check(os.path.isfile(path), f"{relative} is referenced by CI but does not exist"):
            with open(path, "r", encoding="utf-8") as handle:
                check(handle.readline().startswith("#!"),
                      f"{relative} has no shebang but is executed directly")
            check(os.access(path, os.X_OK) or relative.endswith(".py"),
                  f"{relative} is not executable")


def check_xcode_selector() -> None:
    """`Tools/select_xcode.sh` must fail the way its own message claims to.

    It decides whether a release proceeds, so its refusal path is executed here
    rather than read and assumed correct. On a machine that has an Xcode the
    refusal cannot be provoked, so the behavioural half is skipped there.
    """
    script = os.path.join(ROOT, "Tools", "select_xcode.sh")
    if not os.path.isfile(script):
        return
    bash = shutil.which("bash")
    if not check(bash is not None, "bash is unavailable, so select_xcode.sh cannot be checked"):
        return

    result = subprocess.run([str(bash), "-n", script], capture_output=True, text=True)
    check(result.returncode == 0,
          f"Tools/select_xcode.sh is not valid shell: {result.stderr.strip()}")

    # Both variables missing must be refused, not defaulted.
    result = subprocess.run([str(bash), script], capture_output=True, text=True, env={"PATH": os.environ.get("PATH", "")})
    check(result.returncode != 0,
          "Tools/select_xcode.sh runs without MINIMUM_XCODE_VERSION set")

    if glob.glob("/Applications/Xcode*.app"):
        return
    environment = dict(os.environ, MINIMUM_XCODE_VERSION="26.0", MINIMUM_IOS_SDK_VERSION="26.0")
    result = subprocess.run([str(bash), script], capture_output=True, text=True, env=environment)
    check(result.returncode != 0,
          "Tools/select_xcode.sh succeeded on a machine with no Xcode installed")
    check("no installed Xcode" in result.stderr,
          "Tools/select_xcode.sh does not explain why it refused")
    check(result.stdout.strip() == "",
          "Tools/select_xcode.sh wrote to stdout while failing; that would be "
          "appended to $GITHUB_ENV")


def check_simulated_mode_is_real() -> None:
    """The UI tests must actually run the app in its deterministic mode."""
    ui_tests = glob.glob(os.path.join(ROOT, "WallFieldUITests", "**", "*.swift"), recursive=True)
    check(bool(ui_tests), "no UI tests were found")
    body = ""
    for path in ui_tests:
        with open(path, "r", encoding="utf-8") as handle:
            body += handle.read()
    check("-WallFieldDemoMode" in body,
          "the UI tests never launch the app in simulated mode")
    check("-WallFieldResetState" in body,
          "the UI tests never reset persistent state between runs")
    check("launchArguments" in body,
          "the UI tests never set launch arguments")


def check_export_compliance_is_accurate() -> None:
    """`ITSAppUsesNonExemptEncryption = false` must remain true of the code."""
    import plistlib

    plist_path = os.path.join(ROOT, "Config", "WallField-Info.plist")
    if not check(os.path.isfile(plist_path), "Config/WallField-Info.plist is missing"):
        return
    with open(plist_path, "rb") as handle:
        plist = plistlib.load(handle)

    check("ITSAppUsesNonExemptEncryption" in plist,
          "Info.plist does not declare ITSAppUsesNonExemptEncryption")
    check(plist.get("ITSAppUsesNonExemptEncryption") is False,
          f"ITSAppUsesNonExemptEncryption is {plist.get('ITSAppUsesNonExemptEncryption')!r}, "
          "expected false")

    for path in app_swift_sources():
        relative = os.path.relpath(path, ROOT)
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        code = "\n".join(
            span.text for span in swiftsource.scan(source) if span.kind == "code"
        )
        for imported in re.findall(r"^\s*import\s+(\w+)", code, re.MULTILINE):
            check(imported not in ENCRYPTION_IMPORTS,
                  f"{relative}: imports {imported}, which contradicts "
                  "ITSAppUsesNonExemptEncryption = false")
        match = ENCRYPTION_SYMBOLS.search(code)
        check(match is None,
              f"{relative}: uses {match.group(0) if match else ''}, which contradicts "
              "ITSAppUsesNonExemptEncryption = false")

    entitlements = glob.glob(os.path.join(ROOT, "**", "*.entitlements"), recursive=True)
    check(not entitlements,
          f"entitlements files exist and were not reviewed for encryption use: {entitlements}")


# --- entry point -------------------------------------------------------------

_sources: dict[str, str] = {}


def read(filename: str) -> str:
    if filename not in _sources:
        with open(os.path.join(WORKFLOW_DIR, filename), "r", encoding="utf-8") as handle:
            _sources[filename] = handle.read()
    return _sources[filename]


def main() -> int:
    documents: dict[str, dict] = {}
    for filename in (TESTS_WORKFLOW, RELEASE_WORKFLOW):
        path = os.path.join(WORKFLOW_DIR, filename)
        if not check(os.path.isfile(path), f".github/workflows/{filename} is missing"):
            continue
        raw = read(filename)
        check("\t" not in raw, f"{filename} contains a tab character")
        try:
            document = yaml.safe_load(raw)
        except yaml.YAMLError as error:
            failures.append(f"{filename} is not valid YAML: {error}")
            continue
        if check(isinstance(document, dict), f"{filename} is not a mapping"):
            documents[filename] = document

    # Every workflow file in the directory must be one this checker knows about,
    # so a new one cannot be added without being checked.
    present = {os.path.basename(path)
               for path in glob.glob(os.path.join(WORKFLOW_DIR, "*.y*ml"))}
    check(present == {TESTS_WORKFLOW, RELEASE_WORKFLOW},
          f"unexpected workflow files: {sorted(present - {TESTS_WORKFLOW, RELEASE_WORKFLOW})}")

    schemes = shared_schemes()
    bundle_id = xcconfig_value("Config/Signing.xcconfig", "PRODUCT_BUNDLE_IDENTIFIER")
    check(bool(bundle_id), "Config/Signing.xcconfig declares no PRODUCT_BUNDLE_IDENTIFIER")

    for filename, document in documents.items():
        check_common(filename, document, schemes)
    if TESTS_WORKFLOW in documents:
        check_tests_workflow(documents[TESTS_WORKFLOW])
    if RELEASE_WORKFLOW in documents:
        check_release_workflow(documents[RELEASE_WORKFLOW], bundle_id or "", schemes)

    check_repository_scripts()
    check_xcode_selector()
    check_simulated_mode_is_real()
    check_export_compliance_is_accurate()

    print(f"validate_workflows.py: {checks} checks, {len(failures)} failure(s)")
    for failure in sorted(set(failures)):
        print("  FAIL " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate codemagic.yaml against what is actually in this repository.

A CI configuration is a set of claims about a project: that a scheme exists,
that a bundle identifier matches, that a build is exported one way and not
another. Those claims rot silently. This checks them:

* the YAML parses and has the two manual-only workflows this project expects;
* every scheme it names is a *shared* scheme that really exists, and carries
  both test bundles;
* the bundle identifier matches `Config/Signing.xcconfig`;
* the test workflow signs nothing and publishes nothing;
* the release workflow uses automatic App Store signing, an App Store Connect
  integration, and uploads to TestFlight;
* `testFlightInternalTestingOnly` is never enabled, so the same build stays
  eligible for App Store submission;
* no simulator is hard-coded by name -- the destination must be discovered;
* every embedded shell script parses, and the inline version guards behave;
* the shipped `ITSAppUsesNonExemptEncryption = false` is still *true of the
  code*: no encryption or networking API is used anywhere in the app.

Run: ``python3 Tools/validate_codemagic.py``
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
except ImportError:  # pragma: no cover - only hit on a machine without PyYAML
    print("validate_codemagic.py: PyYAML is required (pip3 install pyyaml)")
    sys.exit(1)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "codemagic.yaml")

TEST_WORKFLOW = "wallfield-simulator-tests"
RELEASE_WORKFLOW = "wallfield-testflight"

MINIMUM_XCODE = (26, 4)
MINIMUM_IOS_SDK = (26, 0)

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


def script_bodies(workflow: dict) -> list[tuple[str, str]]:
    """(name, script) for every script step, aliases already resolved."""
    return [
        (step.get("name", "<unnamed>"), step.get("script", ""))
        for step in workflow.get("scripts", [])
        if isinstance(step, dict)
    ]


def joined_scripts(workflow: dict) -> str:
    return "\n".join(body for _, body in script_bodies(workflow))


def joined_code(workflow: dict) -> str:
    """`joined_scripts` with whole-line shell comments removed.

    A comment that *names* a forbidden flag in order to explain why it is not
    used must not read as using it.
    """
    lines = [
        line for line in joined_scripts(workflow).splitlines()
        if not line.lstrip().startswith("#")
    ]
    return "\n".join(lines)


def check_scripts_parse(name: str, workflow: dict) -> None:
    """Every script block must be valid shell.

    A typo in an embedded script is only discovered when the build reaches that
    step, minutes in and after the machine has been paid for. `bash -n` finds it
    in milliseconds.
    """
    bash = shutil.which("bash")
    if not check(bash is not None, "bash is unavailable, so scripts cannot be syntax checked"):
        return
    for step_name, body in script_bodies(workflow):
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
              f"{name}: script {step_name!r} is not valid shell: {result.stderr.strip()}")


def check_inline_python(config_text: str) -> None:
    """The guards written as `python3 -c` one-liners must actually work.

    They decide whether a build proceeds, so they are executed here against known
    inputs rather than read and assumed correct.
    """
    snippets = re.findall(r"python3 -c '([^']+)'", config_text)
    check(len(snippets) >= 2, "expected the inline Python guards in codemagic.yaml")

    comparison = next((snippet for snippet in snippets if "sys.argv" in snippet), None)
    if check(comparison is not None, "no inline version-comparison guard found"):
        for actual, minimum, expected in [
            ("26.4", "26.4", 0),    # equal passes
            ("26.5", "26.4", 0),
            ("27.0", "26.4", 0),
            ("26.10", "26.4", 0),   # numeric, not lexicographic
            ("26.3", "26.4", 1),
            ("16.4", "26.4", 1),
            ("9.9", "26.0", 1),
        ]:
            result = subprocess.run(
                [sys.executable, "-c", str(comparison), actual, minimum],
                capture_output=True,
            )
            check(result.returncode == expected,
                  f"the version guard says {actual} vs minimum {minimum} exits "
                  f"{result.returncode}, expected {expected}")

    newest = next((snippet for snippet in snippets if "sys.stdin" in snippet), None)
    if check(newest is not None, "no inline newest-SDK guard found"):
        for stdin, expected in [
            ("26.0\n18.5\n26.4\n", "26.4"),
            ("9.3\n10.0\n", "10.0"),
            ("", ""),
        ]:
            result = subprocess.run(
                [sys.executable, "-c", str(newest)],
                input=stdin, capture_output=True, text=True,
            )
            check(result.returncode == 0 and result.stdout.strip() == expected,
                  f"the newest-SDK guard given {stdin!r} produced "
                  f"{result.stdout.strip()!r}, expected {expected!r}")


# --- project facts -----------------------------------------------------------

def shared_schemes() -> dict[str, dict]:
    """Every shared scheme, by name, with the blueprint names it references."""
    schemes: dict[str, dict] = {}
    pattern = os.path.join(ROOT, "*.xcodeproj", "xcshareddata", "xcschemes", "*.xcscheme")
    for path in sorted(glob.glob(pattern)):
        name = os.path.splitext(os.path.basename(path))[0]
        tree = ET.parse(path)
        root = tree.getroot()
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

def check_shape(config: dict) -> dict:
    check(isinstance(config.get("workflows"), dict), "codemagic.yaml has no workflows mapping")
    workflows = config.get("workflows") or {}
    check(
        set(workflows) == {TEST_WORKFLOW, RELEASE_WORKFLOW},
        f"expected exactly the workflows {TEST_WORKFLOW} and {RELEASE_WORKFLOW}, "
        f"found {sorted(workflows)}",
    )
    return workflows


def check_common(name: str, workflow: dict, schemes: dict[str, dict]) -> None:
    check("triggering" not in workflow,
          f"{name}: has a triggering block, so it is not manual-only")

    check(workflow.get("instance_type") == "mac_mini_m2",
          f"{name}: instance_type is {workflow.get('instance_type')!r}, expected mac_mini_m2")

    duration = workflow.get("max_build_duration")
    check(isinstance(duration, int) and 0 < duration <= 120,
          f"{name}: max_build_duration is {duration!r}, expected 1-120 minutes")

    environment = workflow.get("environment") or {}
    xcode = str(environment.get("xcode", ""))
    version = parse_version(xcode)
    check(
        xcode in {"latest", "edge"} or (version is not None and version >= MINIMUM_XCODE),
        f"{name}: xcode is {xcode!r}; expected at least "
        f"{'.'.join(map(str, MINIMUM_XCODE))}, or latest/edge",
    )

    variables = environment.get("vars") or {}
    for key, minimum in (("MINIMUM_XCODE_VERSION", MINIMUM_XCODE),
                         ("MINIMUM_IOS_SDK_VERSION", MINIMUM_IOS_SDK)):
        declared = parse_version(str(variables.get(key, "")))
        check(declared is not None and declared >= minimum,
              f"{name}: {key} is {variables.get(key)!r}, expected at least "
              f"{'.'.join(map(str, minimum))}")

    project = variables.get("XCODE_PROJECT")
    check(bool(project) and os.path.isdir(os.path.join(ROOT, str(project))),
          f"{name}: XCODE_PROJECT {project!r} does not exist")

    scheme = variables.get("XCODE_SCHEME")
    if check(scheme in schemes,
             f"{name}: XCODE_SCHEME {scheme!r} is not a shared scheme "
             f"(shared schemes: {sorted(schemes)})"):
        details = schemes[str(scheme)]
        check(set(details["testables"]) == {"WallFieldTests", "WallFieldUITests"},
              f"{name}: scheme {scheme!r} tests {details['testables']}, expected both bundles")
        check("WallField" in details["buildables"],
              f"{name}: scheme {scheme!r} does not build the WallField app target")

    scripts = joined_scripts(workflow)

    check("Tools/check_all.sh" in scripts,
          f"{name}: does not run Tools/check_all.sh")
    check("Tools/select_simulator.py" in scripts,
          f"{name}: does not use the simulator picker")
    check("test-without-building" in scripts or "run-tests" in scripts,
          f"{name}: does not run the test suite")
    check("-resultBundlePath" in scripts,
          f"{name}: does not capture an .xcresult bundle")

    # The destination must be discovered, never named.
    check('id=$SIMULATOR_UDID' in scripts,
          f"{name}: does not target the discovered simulator by UDID")
    hardcoded = re.search(r"-destination\s+[\"']?platform=iOS Simulator[^\"'\n]*name=", scripts)
    check(hardcoded is None,
          f"{name}: hard-codes a simulator by name; the destination must be discovered")

    # No build may enable the internal-testing-only export. Checked against the
    # code only, so a comment explaining the prohibition does not trip it.
    code = joined_code(workflow)
    for pattern in (r"testFlightInternalTestingOnly\s*[:=]\s*(true|YES|1)",
                    r'"testFlightInternalTestingOnly"\s*:\s*true',
                    r"--custom-export-options"):
        check(re.search(pattern, code) is None,
              f"{name}: enables an internal-testing-only export ({pattern})")

    # The same prohibition applies to anything outside the script blocks.
    for key in ("environment", "publishing", "artifacts", "integrations"):
        rendered = yaml.safe_dump(workflow.get(key, {}), default_flow_style=False)
        check("testFlightInternalTestingOnly" not in rendered,
              f"{name}: {key} mentions testFlightInternalTestingOnly")


def check_test_workflow(workflow: dict) -> None:
    name = TEST_WORKFLOW
    scripts = joined_scripts(workflow)

    check("publishing" not in workflow, f"{name}: must not publish anything")
    check("integrations" not in workflow, f"{name}: must not use any integration")
    check("ios_signing" not in (workflow.get("environment") or {}),
          f"{name}: must not configure signing")

    # Signing must be disabled on every xcodebuild invocation.
    invocations = re.findall(r"xcodebuild\s+(build|build-for-testing|test-without-building)\b"
                             r"(?:.|\n)*?(?=\n\s*\n|\Z)", scripts)
    check(len(invocations) >= 3,
          f"{name}: expected build, build-for-testing and test-without-building steps")
    for action in ("build", "build-for-testing", "test-without-building"):
        block = re.search(rf"xcodebuild {action} \\\n((?:.|\n)*?)(?=\n\s*\n|\Z)", scripts)
        if check(block is not None, f"{name}: no xcodebuild {action} invocation found"):
            body = block.group(1)
            for setting in ("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                            'CODE_SIGN_IDENTITY=""'):
                check(setting in body,
                      f"{name}: xcodebuild {action} does not set {setting}")

    artifacts = workflow.get("artifacts") or []
    check(any("xcresult" in item for item in artifacts),
          f"{name}: artifacts do not include the test results")
    check(any(item.endswith(".log") for item in artifacts),
          f"{name}: artifacts do not include the build logs")

    reports = [step.get("test_report") for step in workflow.get("scripts", [])
               if isinstance(step, dict) and step.get("test_report")]
    check(bool(reports), f"{name}: no step declares a test_report")


def check_release_workflow(workflow: dict, bundle_id: str | None) -> None:
    name = RELEASE_WORKFLOW
    environment = workflow.get("environment") or {}
    scripts = joined_scripts(workflow)

    integrations = workflow.get("integrations") or {}
    integration_name = integrations.get("app_store_connect")
    check(isinstance(integration_name, str) and integration_name.strip() != "",
          f"{name}: no App Store Connect integration is named")

    signing = environment.get("ios_signing") or {}
    check(signing.get("distribution_type") == "app_store",
          f"{name}: ios_signing.distribution_type is {signing.get('distribution_type')!r}, "
          "expected app_store")
    check(signing.get("bundle_identifier") == bundle_id,
          f"{name}: ios_signing.bundle_identifier is {signing.get('bundle_identifier')!r}, "
          f"but Config/Signing.xcconfig says {bundle_id!r}")
    check((environment.get("vars") or {}).get("BUNDLE_ID") == bundle_id,
          f"{name}: BUNDLE_ID var does not match Config/Signing.xcconfig ({bundle_id!r})")

    check("xcode-project use-profiles" in scripts,
          f"{name}: never applies the fetched provisioning profiles")
    check("xcode-project build-ipa" in scripts,
          f"{name}: never archives and exports an IPA")

    # A unique, increasing build number must be chosen and actually applied.
    check("WALLFIELD_BUILD_NUMBER=" in scripts and '"$CM_ENV"' in scripts,
          f"{name}: does not export a chosen build number")
    check("$BUILD_NUMBER" in scripts,
          f"{name}: does not use Codemagic's incrementing build counter")
    check("CURRENT_PROJECT_VERSION=$WALLFIELD_BUILD_NUMBER" in scripts,
          f"{name}: the chosen build number is never applied to the archive")

    # The export must be verified, not assumed.
    check("testFlightInternalTestingOnly" in scripts,
          f"{name}: does not assert that the internal-only export is absent")
    check("ITSAppUsesNonExemptEncryption" in scripts,
          f"{name}: does not verify export compliance reached the shipped binary")

    publishing = (workflow.get("publishing") or {}).get("app_store_connect") or {}
    check(publishing.get("auth") == "integration",
          f"{name}: publishing auth is {publishing.get('auth')!r}, expected integration")
    check(publishing.get("submit_to_testflight") is True,
          f"{name}: does not submit the build to TestFlight")
    check(publishing.get("submit_to_app_store") is False,
          f"{name}: submit_to_app_store should be explicitly false")

    artifacts = workflow.get("artifacts") or []
    check(any(item.endswith(".ipa") for item in artifacts),
          f"{name}: the IPA is not kept as an artifact")


def check_repository_scripts() -> None:
    for relative in ("Tools/check_all.sh", "Tools/select_simulator.py"):
        path = os.path.join(ROOT, relative)
        if check(os.path.isfile(path), f"{relative} is referenced by CI but does not exist"):
            with open(path, "r", encoding="utf-8") as handle:
                check(handle.readline().startswith("#!"),
                      f"{relative} has no shebang but is executed directly")
            check(os.access(path, os.X_OK) or relative.endswith(".py"),
                  f"{relative} is not executable")


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


def main() -> int:
    if not check(os.path.isfile(CONFIG), "codemagic.yaml is missing"):
        print(f"validate_codemagic.py: {checks} checks, {len(failures)} failure(s)")
        for failure in failures:
            print("  FAIL " + failure)
        return 1

    with open(CONFIG, "r", encoding="utf-8") as handle:
        raw = handle.read()
    try:
        config = yaml.safe_load(raw)
    except yaml.YAMLError as error:
        print(f"validate_codemagic.py: codemagic.yaml is not valid YAML: {error}")
        return 1

    check(isinstance(config, dict), "codemagic.yaml is not a mapping")
    check("\t" not in raw, "codemagic.yaml contains a tab character")

    schemes = shared_schemes()
    bundle_id = xcconfig_value("Config/Signing.xcconfig", "PRODUCT_BUNDLE_IDENTIFIER")
    check(bool(bundle_id), "Config/Signing.xcconfig declares no PRODUCT_BUNDLE_IDENTIFIER")

    workflows = check_shape(config)
    for name, workflow in workflows.items():
        check_common(name, workflow, schemes)
        check_scripts_parse(name, workflow)
    check_inline_python(raw)
    if TEST_WORKFLOW in workflows:
        check_test_workflow(workflows[TEST_WORKFLOW])
    if RELEASE_WORKFLOW in workflows:
        check_release_workflow(workflows[RELEASE_WORKFLOW], bundle_id)

    check_repository_scripts()
    check_simulated_mode_is_real()
    check_export_compliance_is_accurate()

    print(f"validate_codemagic.py: {checks} checks, {len(failures)} failure(s)")
    for failure in sorted(set(failures)):
        print("  FAIL " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Validate the GitHub Actions workflows against what is in this repository.

The same job `Tools/validate_codemagic.py` does for `codemagic.yaml`. A CI
configuration is a set of claims about a project -- that a scheme exists, that a
bundle identifier matches, that a build is exported one way and not another --
and those claims rot silently, because nothing fails until someone spends
thirty minutes of runner time finding out.

* both workflows parse, and neither can be started by a push;
* the release workflow runs the test workflow first and will not sign or upload
  unless it passed;
* every scheme named is a *shared* scheme that really exists and carries both
  test bundles;
* the bundle identifier matches `Config/Signing.xcconfig`;
* the test workflow signs nothing and uploads nothing;
* `testFlightInternalTestingOnly` is never written, so the same build stays
  eligible for App Store submission;
* no simulator is hard-coded by name -- the destination must be discovered;
* the chosen build number reaches the archive, and the shipped `Info.plist` is
  checked before anything is uploaded;
* every `run:` block is valid shell, heredocs included;
* every `Tools/` script the workflows call exists and is runnable;
* every secret the workflows read is documented in
  `Docs/RELEASE_TO_TESTFLIGHT.md`, so the setup instructions cannot drift from
  what the workflow actually requires.

Run: ``python3 Tools/validate_github_workflows.py``
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from validate_codemagic import shared_schemes, xcconfig_value  # noqa: E402

try:
    import yaml
except ImportError:  # pragma: no cover - only hit on a machine without PyYAML
    print("validate_github_workflows.py: PyYAML is required (pip3 install pyyaml)")
    sys.exit(1)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW_DIR = os.path.join(ROOT, ".github", "workflows")

TEST_WORKFLOW = "tests.yml"
RELEASE_WORKFLOW = "testflight.yml"
SETUP_DOC = os.path.join(ROOT, "Docs", "RELEASE_TO_TESTFLIGHT.md")

# Triggers that would start a build without a person asking for it.
AUTOMATIC_TRIGGERS = {"push", "pull_request", "pull_request_target", "schedule", "release"}

EXPRESSION = re.compile(r"\$\{\{[^}]*\}\}")

failures: list[str] = []
checks = 0


def check(condition: bool, message: str) -> bool:
    global checks
    checks += 1
    if not condition:
        failures.append(message)
    return bool(condition)


# --- reading -----------------------------------------------------------------

def load(name: str) -> dict | None:
    path = os.path.join(WORKFLOW_DIR, name)
    if not check(os.path.isfile(path), f"{name} is missing from .github/workflows"):
        return None
    with open(path, "r", encoding="utf-8") as handle:
        try:
            document = yaml.safe_load(handle)
        except yaml.YAMLError as error:
            check(False, f"{name} is not valid YAML: {error}")
            return None
    if not check(isinstance(document, dict), f"{name} is not a mapping"):
        return None
    return document


def triggers(workflow: dict) -> dict:
    """The `on:` block.

    YAML 1.1 reads a bare `on` as the boolean `True`, which is why this looks
    under both keys rather than assuming the string.
    """
    for key in ("on", True):
        if key in workflow:
            value = workflow[key]
            return value if isinstance(value, dict) else {str(value): None}
    return {}


def jobs(workflow: dict) -> dict:
    value = workflow.get("jobs")
    return value if isinstance(value, dict) else {}


def run_blocks(workflow: dict) -> list[tuple[str, str]]:
    """(step name, script) for every `run:` step in every job."""
    blocks: list[tuple[str, str]] = []
    for job_name, job in jobs(workflow).items():
        if not isinstance(job, dict):
            continue
        for index, step in enumerate(job.get("steps") or []):
            if isinstance(step, dict) and isinstance(step.get("run"), str):
                label = step.get("name") or f"step {index}"
                blocks.append((f"{job_name}/{label}", step["run"]))
    return blocks


def joined_runs(workflow: dict) -> str:
    return "\n".join(body for _, body in run_blocks(workflow))


def joined_code(workflow: dict) -> str:
    """`joined_runs` with whole-line shell comments removed.

    A comment that *names* a forbidden flag in order to explain why it is not
    used must not read as using it.
    """
    return "\n".join(
        line for line in joined_runs(workflow).splitlines()
        if not line.lstrip().startswith("#")
    )


# --- checks ------------------------------------------------------------------

def check_manual_only(name: str, workflow: dict) -> None:
    on = triggers(workflow)
    check("workflow_dispatch" in on, f"{name}: cannot be started by hand")
    automatic = sorted(AUTOMATIC_TRIGGERS.intersection(on))
    check(
        not automatic,
        f"{name}: has the automatic trigger(s) {automatic}. Both workflows are "
        "manual on purpose; a release must not be a side effect of a push.",
    )


def check_runs_parse(name: str, workflow: dict) -> None:
    """Every `run:` block must be valid shell.

    A typo in an embedded script is only discovered when the job reaches that
    step, minutes in and after the runner has been paid for. `bash -n` finds it
    in milliseconds -- including an unterminated heredoc, which indentation
    inside a YAML block scalar makes easy to get wrong.
    """
    bash = shutil.which("bash")
    if not check(bash is not None, "bash is unavailable, so run blocks cannot be syntax checked"):
        return
    for step_name, body in run_blocks(workflow):
        if not body.strip():
            continue
        # `${{ ... }}` is an Actions expression, not shell. Substitute a plain
        # word so the rest of the block can still be parsed.
        script = EXPRESSION.sub("EXPRESSION", body)
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
            handle.write(script)
            path = handle.name
        try:
            result = subprocess.run([str(bash), "-n", path], capture_output=True, text=True)
        finally:
            os.unlink(path)
        check(result.returncode == 0,
              f"{name}: run block {step_name!r} is not valid shell: {result.stderr.strip()}")


def check_scheme(name: str, workflow: dict, schemes: dict[str, dict]) -> None:
    text = joined_runs(workflow)
    for job in jobs(workflow).values():
        if not isinstance(job, dict):
            continue
        text += "\n" + yaml.safe_dump(job.get("env") or {})
    text += "\n" + yaml.safe_dump(workflow.get("env") or {})

    project = re.search(r"XCODE_PROJECT:\s*(\S+)", text)
    if check(project is not None, f"{name}: does not name an Xcode project"):
        path = project.group(1).strip("'\"")
        check(os.path.isdir(os.path.join(ROOT, path)),
              f"{name}: names {path}, which is not in the repository")

    scheme = re.search(r"XCODE_SCHEME:\s*(\S+)", text)
    if not check(scheme is not None, f"{name}: does not name a scheme"):
        return
    scheme_name = scheme.group(1).strip("'\"")
    if check(scheme_name in schemes,
             f"{name}: names scheme {scheme_name!r}, which is not a shared scheme"):
        details = schemes[scheme_name]
        check(set(details["testables"]) == {"WallFieldTests", "WallFieldUITests"},
              f"{name}: scheme {scheme_name!r} does not carry both test bundles")
        check("WallField" in details["buildables"],
              f"{name}: scheme {scheme_name!r} does not build the app target")


def check_no_hardcoded_simulator(name: str, workflow: dict) -> None:
    code = joined_code(workflow)
    check("Tools/select_simulator.py" in code,
          f"{name}: does not discover a simulator with Tools/select_simulator.py")
    check("id=$SIMULATOR_UDID" in code,
          f"{name}: does not build against the discovered simulator UDID")
    hardcoded = re.search(r"name=iPhone[^\"']*", code)
    check(hardcoded is None,
          f"{name}: hard-codes a simulator by name ({hardcoded.group(0) if hardcoded else ''})")


def check_test_workflow(workflow: dict) -> None:
    name = TEST_WORKFLOW
    check_manual_only(name, workflow)
    on = triggers(workflow)
    check("workflow_call" in on,
          f"{name}: is not reusable, so the release workflow cannot depend on it")

    code = joined_code(workflow)
    check("Tools/check_all.sh" in code, f"{name}: does not run the repository checks")
    check("test-without-building" in code, f"{name}: does not run the tests")
    check("-resultBundlePath" in code, f"{name}: does not keep an .xcresult bundle")

    for action in ("build", "build-for-testing", "test-without-building"):
        block = re.search(rf"xcodebuild {re.escape(action)}\b.*?(?=\n\s*\n|\Z)", code, re.S)
        if check(block is not None, f"{name}: no xcodebuild {action} invocation found"):
            for setting in ("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"):
                check(setting in block.group(0),
                      f"{name}: xcodebuild {action} does not disable code signing ({setting})")

    for forbidden in ("altool", "--upload-app", "xcodebuild -exportArchive", "security import"):
        check(forbidden not in code,
              f"{name}: references {forbidden!r}; this workflow must sign and publish nothing")


def check_release_workflow(workflow: dict, bundle_id: str | None) -> None:
    name = RELEASE_WORKFLOW
    check_manual_only(name, workflow)

    all_jobs = jobs(workflow)
    verify = all_jobs.get("verify")
    if check(isinstance(verify, dict), f"{name}: has no verify job"):
        check(str(verify.get("uses", "")).endswith(f"/{TEST_WORKFLOW}"),
              f"{name}: the verify job does not run {TEST_WORKFLOW}")

    release = all_jobs.get("release")
    if not check(isinstance(release, dict), f"{name}: has no release job"):
        return
    needs = release.get("needs")
    needs = [needs] if isinstance(needs, str) else (needs or [])
    check("verify" in needs,
          f"{name}: the release job does not require the verify job, so it could "
          "sign and upload a build whose tests never ran")
    check("if" not in release,
          f"{name}: the release job has an `if:` condition, which can let it run "
          "even when verification did not succeed")

    declared = (release.get("env") or {}).get("BUNDLE_ID")
    check(declared == bundle_id,
          f"{name}: BUNDLE_ID is {declared!r} but Config/Signing.xcconfig says {bundle_id!r}")

    code = joined_code(workflow)
    check("xcodebuild archive" in code, f"{name}: never archives")
    check("xcodebuild -exportArchive" in code, f"{name}: never exports an archive")
    check("CURRENT_PROJECT_VERSION=\"$WALLFIELD_BUILD_NUMBER\"" in code,
          f"{name}: the chosen build number is not passed to the archive")
    check("Tools/appstore_build_number.py" in code,
          f"{name}: does not choose a build number against App Store Connect")
    check("manageAppVersionAndBuildNumber" in joined_runs(workflow),
          f"{name}: does not stop Xcode renumbering the build during export")

    check("testFlightInternalTestingOnly" in joined_runs(workflow),
          f"{name}: does not assert testFlightInternalTestingOnly is absent")
    check("PlistBuddy -c 'Print :testFlightInternalTestingOnly'" in code
          or 'PlistBuddy -c "Print :testFlightInternalTestingOnly"' in code,
          f"{name}: does not read testFlightInternalTestingOnly back to check it")
    check(re.search(r"<key>testFlightInternalTestingOnly</key>", joined_runs(workflow)) is None,
          f"{name}: writes testFlightInternalTestingOnly into the export options")

    for key in ("CFBundleIdentifier", "CFBundleVersion", "ITSAppUsesNonExemptEncryption"):
        check(key in code, f"{name}: does not verify {key} in the shipped Info.plist")

    check("security delete-keychain" in code,
          f"{name}: never removes the signing keychain it created")
    cleanup = [
        step for job in all_jobs.values() if isinstance(job, dict)
        for step in (job.get("steps") or [])
        if isinstance(step, dict) and "delete-keychain" in str(step.get("run", ""))
    ]
    check(any("always()" in str(step.get("if", "")) for step in cleanup),
          f"{name}: signing material is not removed when a step fails")


def check_referenced_tools(workflows: dict[str, dict]) -> None:
    referenced: set[str] = set()
    for workflow in workflows.values():
        referenced.update(re.findall(r"Tools/[A-Za-z0-9_]+\.(?:py|sh)", joined_runs(workflow)))
    check(bool(referenced), "the workflows reference no repository tooling at all")
    for relative in sorted(referenced):
        path = os.path.join(ROOT, relative)
        if check(os.path.isfile(path), f"{relative} is referenced by CI but does not exist"):
            with open(path, "r", encoding="utf-8") as handle:
                check(handle.readline().startswith("#!"),
                      f"{relative} has no shebang but is executed by CI")


def check_secrets_are_documented(workflows: dict[str, dict]) -> None:
    """Every secret the workflows read must appear in the setup instructions.

    A workflow that needs a ninth secret nobody was told about fails at the
    first step, which is survivable -- but only if the instructions are the
    thing that gets fixed, and they are only fixed if something notices.
    """
    used: set[str] = set()
    for name, path in ((n, os.path.join(WORKFLOW_DIR, n)) for n in workflows):
        with open(path, "r", encoding="utf-8") as handle:
            used.update(re.findall(r"secrets\.([A-Z0-9_]+)", handle.read()))
    if not check(bool(used), "the release workflow reads no secrets at all"):
        return
    if not check(os.path.isfile(SETUP_DOC), "Docs/RELEASE_TO_TESTFLIGHT.md is missing"):
        return
    with open(SETUP_DOC, "r", encoding="utf-8") as handle:
        documentation = handle.read()
    for secret in sorted(used):
        check(secret in documentation,
              f"secret {secret} is read by a workflow but not documented in "
              "Docs/RELEASE_TO_TESTFLIGHT.md")


def main() -> int:
    if not check(os.path.isdir(WORKFLOW_DIR), ".github/workflows does not exist"):
        report()
        return 1

    documents = {}
    for name in (TEST_WORKFLOW, RELEASE_WORKFLOW):
        document = load(name)
        if document is not None:
            documents[name] = document

    schemes = shared_schemes()
    bundle_id = xcconfig_value("Config/Signing.xcconfig", "PRODUCT_BUNDLE_IDENTIFIER")
    check(bool(bundle_id), "Config/Signing.xcconfig declares no PRODUCT_BUNDLE_IDENTIFIER")

    for name, document in documents.items():
        check_runs_parse(name, document)
        check_scheme(name, document, schemes)

    if TEST_WORKFLOW in documents:
        check_no_hardcoded_simulator(TEST_WORKFLOW, documents[TEST_WORKFLOW])
        check_test_workflow(documents[TEST_WORKFLOW])
    if RELEASE_WORKFLOW in documents:
        check_release_workflow(documents[RELEASE_WORKFLOW], bundle_id)

    check_referenced_tools(documents)
    check_secrets_are_documented(documents)

    report()
    return 1 if failures else 0


def report() -> None:
    print(f"validate_github_workflows.py: {checks} checks, {len(failures)} failure(s)")
    for failure in failures:
        print("  FAIL " + failure)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Structural validation of WallField.xcodeproj.

This does not compile anything -- no Swift toolchain exists on this machine --
but it does catch the failure modes a hand-generated Xcode project is actually
prone to: dangling object references, orphaned objects, targets missing a build
phase, file references that point at paths which do not exist on disk, schemes
whose blueprint identifiers do not match any target, schemes whose test action
cannot actually run, and xcconfig ``#include`` chains that do not resolve.

Exit status is non-zero when any check fails.
"""

from __future__ import annotations

import os
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pbxproj  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "WallField.xcodeproj")
PBXPROJ = os.path.join(PROJECT, "project.pbxproj")
ID_RE = re.compile(r"^[0-9A-F]{24}$")

failures: list[str] = []
checks = 0


def check(condition: bool, message: str) -> bool:
    global checks
    checks += 1
    if not condition:
        failures.append(message)
    return bool(condition)


def walk_ids(value, out: set[str]) -> None:
    if isinstance(value, str):
        if ID_RE.match(value):
            out.add(value)
    elif isinstance(value, list):
        for item in value:
            walk_ids(item, out)
    elif isinstance(value, dict):
        for item in value.values():
            walk_ids(item, out)


def main() -> int:
    check(os.path.isfile(PBXPROJ), "project.pbxproj is missing")
    if failures:
        print("\n".join(failures))
        return 1

    project = pbxproj.load(PBXPROJ)
    objects: dict[str, dict] = project["objects"]

    check(project["archiveVersion"] == "1", "archiveVersion must be 1")
    check(project["objectVersion"] == "77",
          "objectVersion must be 77 (file-system-synchronized groups)")
    root_id = project["rootObject"]
    check(root_id in objects, "rootObject is not present in the objects table")

    # 1. every identifier-shaped string must resolve to a defined object -------
    referenced: set[str] = set()
    walk_ids(objects, referenced)
    walk_ids(project.get("rootObject"), referenced)
    dangling = sorted(referenced - set(objects))
    check(not dangling, f"dangling object references: {dangling}")

    # 2. every defined object must be reachable from the root -----------------
    reachable: set[str] = set()
    frontier = [root_id]
    while frontier:
        current = frontier.pop()
        if current in reachable or current not in objects:
            continue
        reachable.add(current)
        found: set[str] = set()
        walk_ids(objects[current], found)
        frontier.extend(found)
    orphans = sorted(set(objects) - reachable)
    check(not orphans,
          f"orphaned objects unreachable from rootObject: "
          f"{[(o, objects[o].get('isa')) for o in orphans]}")

    # 3. project object ------------------------------------------------------
    root = objects[root_id]
    check(root.get("isa") == "PBXProject", "rootObject is not a PBXProject")
    targets = root.get("targets", [])
    check(len(targets) == 3, f"expected 3 targets, found {len(targets)}")

    expected_types = {
        "WallField": "com.apple.product-type.application",
        "WallFieldTests": "com.apple.product-type.bundle.unit-test",
        "WallFieldUITests": "com.apple.product-type.bundle.ui-testing",
    }
    seen_targets: dict[str, str] = {}
    for target_id in targets:
        target = objects[target_id]
        name = target.get("name", "?")
        seen_targets[name] = target_id
        check(target.get("isa") == "PBXNativeTarget", f"{name}: not a PBXNativeTarget")
        check(target.get("productType") == expected_types.get(name),
              f"{name}: unexpected productType {target.get('productType')!r}")
        phases = [objects[p].get("isa") for p in target.get("buildPhases", [])]
        for required in ("PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"):
            check(required in phases, f"{name}: missing {required}")
        sync = target.get("fileSystemSynchronizedGroups", [])
        check(len(sync) == 1, f"{name}: expected exactly one synchronized root group")
        for group_id in sync:
            group = objects[group_id]
            check(group.get("isa") == "PBXFileSystemSynchronizedRootGroup",
                  f"{name}: synchronized group has wrong isa")
            path = group.get("path", "")
            check(os.path.isdir(os.path.join(ROOT, path)),
                  f"{name}: synchronized folder {path!r} does not exist on disk")
            check(path == name, f"{name}: synchronized folder {path!r} does not match target name")
        product = objects.get(target.get("productReference", ""), {})
        check(product.get("isa") == "PBXFileReference", f"{name}: productReference is not a file reference")
        cfg_list = objects.get(target.get("buildConfigurationList", ""), {})
        check(cfg_list.get("isa") == "XCConfigurationList", f"{name}: missing configuration list")
        names = sorted(objects[c].get("name") for c in cfg_list.get("buildConfigurations", []))
        check(names == ["Debug", "Release"], f"{name}: configurations are {names}, expected Debug+Release")

    check(sorted(seen_targets) == sorted(expected_types),
          f"target names are {sorted(seen_targets)}")

    # 4. test targets depend on the app --------------------------------------
    app_id = seen_targets.get("WallField")
    for test_name in ("WallFieldTests", "WallFieldUITests"):
        target = objects.get(seen_targets.get(test_name, ""), {})
        deps = target.get("dependencies", [])
        check(len(deps) == 1, f"{test_name}: expected exactly one target dependency")
        for dep_id in deps:
            dep = objects[dep_id]
            check(dep.get("isa") == "PBXTargetDependency", f"{test_name}: bad dependency isa")
            check(dep.get("target") == app_id, f"{test_name}: does not depend on the WallField app target")
            proxy = objects.get(dep.get("targetProxy", ""), {})
            check(proxy.get("remoteGlobalIDString") == app_id,
                  f"{test_name}: container proxy does not point at the app target")

    # 5. unit tests are hosted, ui tests target the app ----------------------
    def target_settings(target_name: str) -> dict:
        target = objects[seen_targets[target_name]]
        merged: dict[str, object] = {}
        for cfg_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
            merged.update(objects[cfg_id].get("buildSettings", {}))
        return merged

    unit = target_settings("WallFieldTests")
    check("TEST_HOST" in unit, "WallFieldTests: TEST_HOST is not set (needed for @testable import)")
    check(unit.get("BUNDLE_LOADER") == "$(TEST_HOST)", "WallFieldTests: BUNDLE_LOADER must be $(TEST_HOST)")
    ui = target_settings("WallFieldUITests")
    check(ui.get("TEST_TARGET_NAME") == "WallField", "WallFieldUITests: TEST_TARGET_NAME must be WallField")

    app = target_settings("WallField")
    check(app.get("GENERATE_INFOPLIST_FILE") == "NO", "WallField: expected an explicit Info.plist")
    info_plist = app.get("INFOPLIST_FILE", "")
    check(os.path.isfile(os.path.join(ROOT, info_plist)),
          f"WallField: INFOPLIST_FILE {info_plist!r} does not exist")

    # 6. every group-relative file reference exists on disk -------------------
    parents: dict[str, str] = {}
    for obj_id, obj in objects.items():
        if obj.get("isa") == "PBXGroup":
            for child in obj.get("children", []):
                parents[child] = obj_id

    def resolve(obj_id: str) -> str:
        segments: list[str] = []
        current: str | None = obj_id
        while current:
            obj = objects[current]
            if obj.get("sourceTree") == "BUILT_PRODUCTS_DIR":
                return ""  # build artefact, nothing to check on disk
            path = obj.get("path")
            if path:
                segments.append(path)
            current = parents.get(current)
        return os.path.join(*reversed(segments)) if segments else ""

    for obj_id, obj in objects.items():
        if obj.get("isa") != "PBXFileReference":
            continue
        relative = resolve(obj_id)
        if not relative:
            continue
        check(os.path.exists(os.path.join(ROOT, relative)),
              f"file reference points at a missing path: {relative}")

    # 7. project-level configurations point at the xcconfig files ------------
    project_cfg = objects[root["buildConfigurationList"]]
    for cfg_id in project_cfg["buildConfigurations"]:
        cfg = objects[cfg_id]
        base_id = cfg.get("baseConfigurationReference")
        check(bool(base_id), f"project {cfg.get('name')} configuration has no xcconfig")
        if base_id:
            base_path = resolve(base_id)
            check(os.path.isfile(os.path.join(ROOT, base_path)),
                  f"xcconfig {base_path!r} does not exist")

    # 8. xcconfig include chains resolve -------------------------------------
    include_re = re.compile(r'^#include\??\s+"([^"]+)"', re.MULTILINE)
    for name in os.listdir(os.path.join(ROOT, "Config")):
        if not name.endswith(".xcconfig"):
            continue
        path = os.path.join(ROOT, "Config", name)
        with open(path, "r", encoding="utf-8") as handle:
            body = handle.read()
        for match in include_re.finditer(body):
            optional = body[match.start():match.start() + 9].startswith("#include?")
            target_path = os.path.join(ROOT, "Config", match.group(1))
            if not optional:
                check(os.path.isfile(target_path),
                      f"{name}: #include {match.group(1)!r} does not resolve")

    # 9. no Team ID or bundle-id placeholder leaked into signing config ------
    with open(os.path.join(ROOT, "Config", "Signing.xcconfig"), "r", encoding="utf-8") as handle:
        signing = handle.read()
    team_line = [ln for ln in signing.splitlines()
                 if ln.strip().startswith("DEVELOPMENT_TEAM") and not ln.strip().startswith("//")]
    check(len(team_line) == 1 and team_line[0].split("=", 1)[1].strip() == "",
          "Config/Signing.xcconfig must not contain a hard-coded Apple Team ID")

    # 10. shared schemes -----------------------------------------------------
    schemes_dir = os.path.join(PROJECT, "xcshareddata", "xcschemes")
    scheme_files = sorted(f for f in os.listdir(schemes_dir) if f.endswith(".xcscheme"))
    check(len(scheme_files) >= 1, "no shared schemes found")
    valid_ids = set(seen_targets.values())
    for scheme_name in scheme_files:
        tree = ET.parse(os.path.join(schemes_dir, scheme_name))
        blueprints = {node.get("BlueprintIdentifier")
                      for node in tree.iter("BuildableReference")}
        unknown = sorted(b for b in blueprints if b not in valid_ids)
        check(not unknown, f"{scheme_name}: references unknown targets {unknown}")
        testables = list(tree.iter("TestableReference"))
        if scheme_name == "WallField.xcscheme":
            check(len(testables) == 2, f"{scheme_name}: expected both test bundles in the test action")

        # xcodebuild refuses to test a scheme that declares a TestPlans element
        # but references no plan: "the scheme uses test plans but has no test
        # plan(s) associated with it". An empty element is enough to trigger it,
        # so the scheme must either name at least one plan or list its bundles
        # directly. Parsed as XML, so a comment mentioning the element is not
        # mistaken for the element.
        test_action = tree.find("TestAction")
        check(test_action is not None, f"{scheme_name}: has no TestAction")
        if test_action is not None:
            plans_element = test_action.find("TestPlans")
            plan_references = list(test_action.iter("TestPlanReference"))
            if plans_element is not None:
                check(len(plan_references) > 0,
                      f"{scheme_name}: declares a TestPlans element but references no test "
                      "plan, so xcodebuild cannot test this scheme")
            else:
                check(len(testables) > 0,
                      f"{scheme_name}: has neither a test plan nor any TestableReference, "
                      "so there is nothing to test")

    print(f"validate_project.py: {checks} checks, {len(failures)} failure(s)")
    for failure in failures:
        print("  FAIL " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

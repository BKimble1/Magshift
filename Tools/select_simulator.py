#!/usr/bin/env python3
"""Choose an iOS Simulator that actually exists on the build machine.

CI configurations that hard-code a device name ("iPhone 15") break silently
every time the runner image changes. This reads what `simctl` reports and picks
the newest available iPhone on the newest available iOS runtime, then prints
shell-assignable lines for the CI to consume:

    SIMULATOR_UDID=...
    SIMULATOR_LABEL=iPhone_17_Pro_iOS_26.4

Usage:
    xcrun simctl list devices available --json > devices.json
    python3 Tools/select_simulator.py devices.json

    python3 Tools/select_simulator.py --self-test   # no Xcode required

Exits non-zero with a specific message when no usable simulator exists, which is
a far better failure than `xcodebuild` reporting an unavailable destination.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

RUNTIME_RE = re.compile(r"SimRuntime\.iOS-(\d+)-(\d+)(?:-(\d+))?$")

# Preferred device families, best first. A pinned model is never assumed: this
# only breaks ties between whatever the machine actually has.
FAMILY_RANK = ["iPhone"]


class NoSimulatorAvailable(RuntimeError):
    pass


def runtime_version(identifier: str) -> tuple[int, ...] | None:
    """`...SimRuntime.iOS-26-4` -> (26, 4, 0). `None` if it is not an iOS runtime."""
    match = RUNTIME_RE.search(identifier)
    if not match:
        return None
    major, minor, patch = match.group(1), match.group(2), match.group(3)
    return (int(major), int(minor), int(patch or 0))


def device_rank(device: dict) -> tuple:
    """Newest-looking iPhone first.

    Ranked by the largest number in the name (the model generation), then by
    whether it is a Pro/Pro Max variant, then by name for determinism.
    """
    name = device.get("name", "")
    numbers = [int(token) for token in re.findall(r"\d+", name)]
    generation = max(numbers) if numbers else 0
    variant = 2 if "Pro Max" in name else 1 if "Pro" in name else 0
    return (generation, variant, name)


def choose(devices_json: dict) -> dict:
    """Returns `{udid, name, runtime}` for the simulator to test on."""
    by_runtime = devices_json.get("devices") or {}

    candidates: list[tuple[tuple[int, ...], str, list[dict]]] = []
    for identifier, devices in by_runtime.items():
        version = runtime_version(identifier)
        if version is None:
            continue
        usable = [
            device for device in devices
            # `simctl list ... available` already filters, but the flag is easy
            # to forget and an unavailable device fails much later and less
            # clearly, so the check is repeated here.
            if device.get("isAvailable", True) and device.get("udid")
        ]
        if usable:
            candidates.append((version, identifier, usable))

    if not candidates:
        raise NoSimulatorAvailable(
            "No iOS simulator runtime with an available device was found. "
            "Install an iOS runtime, or pick a different Xcode version."
        )

    version, identifier, devices = max(candidates, key=lambda item: item[0])

    for family in FAMILY_RANK:
        matching = [device for device in devices if device.get("name", "").startswith(family)]
        if matching:
            chosen = max(matching, key=device_rank)
            break
    else:
        # No preferred family on this runtime. Anything available beats failing,
        # and the label makes the substitution obvious in the build log.
        chosen = max(devices, key=device_rank)

    return {
        "udid": chosen["udid"],
        "name": chosen.get("name", "unknown"),
        "runtime": "iOS " + ".".join(str(part) for part in version[:2]),
    }


def format_environment(selection: dict) -> str:
    label = f"{selection['name']} {selection['runtime']}"
    # Spaces are stripped so the value survives any `KEY=value` consumer.
    safe_label = re.sub(r"[^A-Za-z0-9._-]+", "_", label).strip("_")
    return f"SIMULATOR_UDID={selection['udid']}\nSIMULATOR_LABEL={safe_label}"


# --- self test ---------------------------------------------------------------

SELF_TEST_CASES: list[tuple[str, dict, dict]] = [
    (
        "picks the newest runtime and the newest Pro Max iPhone on it",
        {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
                    {"udid": "OLD-1", "name": "iPhone 16 Pro Max", "isAvailable": True},
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                    {"udid": "NEW-1", "name": "iPhone 17", "isAvailable": True},
                    {"udid": "NEW-2", "name": "iPhone 17 Pro Max", "isAvailable": True},
                    {"udid": "NEW-3", "name": "iPhone 17 Pro", "isAvailable": True},
                ],
                "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [
                    {"udid": "W-1", "name": "Apple Watch Series 11", "isAvailable": True},
                ],
            }
        },
        {"udid": "NEW-2", "runtime": "iOS 26.4"},
    ),
    (
        "ignores unavailable devices",
        {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"udid": "BAD", "name": "iPhone 17 Pro", "isAvailable": False},
                    {"udid": "GOOD", "name": "iPhone 17", "isAvailable": True},
                ]
            }
        },
        {"udid": "GOOD", "runtime": "iOS 26.0"},
    ),
    (
        "ignores a runtime whose devices are all unavailable, even if it is newer",
        {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    {"udid": "BAD", "name": "iPhone 18", "isAvailable": False},
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                    {"udid": "GOOD", "name": "iPhone 17", "isAvailable": True},
                ],
            }
        },
        {"udid": "GOOD", "runtime": "iOS 26.4"},
    ),
    (
        "falls back to a non-iPhone device rather than failing",
        {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                    {"udid": "PAD", "name": "iPad Pro 13-inch (M4)", "isAvailable": True},
                ]
            }
        },
        {"udid": "PAD", "runtime": "iOS 26.2"},
    ),
    (
        "handles a three-component runtime identifier",
        {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-4-1": [
                    {"udid": "PATCHED", "name": "iPhone 17", "isAvailable": True},
                ]
            }
        },
        {"udid": "PATCHED", "runtime": "iOS 26.4"},
    ),
]


def self_test() -> int:
    failures = 0
    for description, payload, expected in SELF_TEST_CASES:
        try:
            actual = choose(payload)
        except NoSimulatorAvailable as error:
            print(f"  FAIL {description}: raised {error}")
            failures += 1
            continue
        for key, value in expected.items():
            if actual[key] != value:
                print(f"  FAIL {description}: {key} was {actual[key]!r}, expected {value!r}")
                failures += 1

    for description, payload in [
        ("empty payload", {}),
        ("no iOS runtimes", {"devices": {
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [
                {"udid": "TV", "name": "Apple TV", "isAvailable": True}
            ]
        }}),
        ("iOS runtime with no devices", {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": []
        }}),
    ]:
        try:
            choose(payload)
        except NoSimulatorAvailable:
            pass
        else:
            print(f"  FAIL {description}: should have raised NoSimulatorAvailable")
            failures += 1

    label = format_environment({"udid": "U", "name": "iPhone 17 Pro Max", "runtime": "iOS 26.4"})
    if label != "SIMULATOR_UDID=U\nSIMULATOR_LABEL=iPhone_17_Pro_Max_iOS_26.4":
        print(f"  FAIL label formatting: {label!r}")
        failures += 1

    total = len(SELF_TEST_CASES) + 3 + 1
    print(f"select_simulator.py: {total} self-test cases, {failures} failure(s)")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("devices_json", nargs="?",
                        help="output of `xcrun simctl list devices available --json`; "
                             "reads stdin when omitted")
    parser.add_argument("--self-test", action="store_true",
                        help="run the built-in test cases and exit")
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()

    if arguments.devices_json:
        with open(arguments.devices_json, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    else:
        payload = json.load(sys.stdin)

    try:
        selection = choose(payload)
    except NoSimulatorAvailable as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(format_environment(selection))
    return 0


if __name__ == "__main__":
    sys.exit(main())

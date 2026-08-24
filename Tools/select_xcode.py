#!/usr/bin/env python3
"""Choose an installed Xcode that meets this project's floor.

Codemagic picks the toolchain for you with its `xcode:` key. A GitHub Actions
runner does not: it ships several Xcodes side by side and `xcode-select` points
at whichever one the image maintainers chose that month. Pinning a path breaks
every time the image changes, and taking whatever is current silently builds
with the wrong SDK.

So this reads the version out of each installed Xcode's `version.plist` -- no
subprocess, no `xcodebuild`, nothing to launch -- and picks the newest one that
meets the required minimum. It prints shell-assignable lines for the CI to
consume:

    DEVELOPER_DIR=/Applications/Xcode_26.4.app/Contents/Developer
    XCODE_VERSION=26.4
    XCODE_APP=/Applications/Xcode_26.4.app

Usage:
    python3 Tools/select_xcode.py --minimum 26.4
    python3 Tools/select_xcode.py --minimum 26.4 --search /Applications
    python3 Tools/select_xcode.py --self-test    # no Xcode required

Exits non-zero, listing every version it did find, when none qualifies. That is
a far better failure than a build that succeeds against an SDK Apple will
refuse at upload.
"""

from __future__ import annotations

import argparse
import glob
import os
import plistlib
import sys

DEFAULT_SEARCH = "/Applications"


class NoUsableXcode(RuntimeError):
    pass


def parse_version(text: str) -> tuple[int, ...] | None:
    """`"26.4"` -> `(26, 4)`. `None` when it is not a dotted numeric version."""
    if not text:
        return None
    parts = text.strip().split(".")
    if not all(part.isdigit() for part in parts):
        return None
    return tuple(int(part) for part in parts)


def padded(version: tuple[int, ...], length: int = 3) -> tuple[int, ...]:
    """Compare `26.4` and `26.4.1` without one sorting above the other by luck."""
    return tuple(list(version) + [0] * (length - len(version)))[:length]


def version_of(app_path: str) -> tuple[int, ...] | None:
    """The marketing version of one `Xcode*.app`, from its `version.plist`."""
    plist_path = os.path.join(app_path, "Contents", "version.plist")
    try:
        with open(plist_path, "rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return None
    return parse_version(str(plist.get("CFBundleShortVersionString", "")))


def installed(search: str = DEFAULT_SEARCH) -> list[tuple[tuple[int, ...], str]]:
    """Every readable `Xcode*.app` under `search`, as (version, path)."""
    found: list[tuple[tuple[int, ...], str]] = []
    for path in sorted(glob.glob(os.path.join(search, "Xcode*.app"))):
        version = version_of(path)
        if version is not None:
            found.append((version, path))
    return found


def choose(
    candidates: list[tuple[tuple[int, ...], str]],
    minimum: tuple[int, ...],
) -> tuple[tuple[int, ...], str]:
    """The newest candidate meeting `minimum`.

    Ties on version are broken by path, so the choice is deterministic rather
    than dependent on directory order.
    """
    if not candidates:
        raise NoUsableXcode("no Xcode installation was found")
    usable = [item for item in candidates if padded(item[0]) >= padded(minimum)]
    if not usable:
        available = ", ".join(
            f"{'.'.join(str(part) for part in version)} ({os.path.basename(path)})"
            for version, path in sorted(candidates)
        )
        raise NoUsableXcode(
            f"no installed Xcode meets the required minimum "
            f"{'.'.join(str(part) for part in minimum)}. Found: {available}"
        )
    return max(usable, key=lambda item: (padded(item[0]), item[1]))


def format_environment(version: tuple[int, ...], app_path: str) -> str:
    return "\n".join([
        f"DEVELOPER_DIR={os.path.join(app_path, 'Contents', 'Developer')}",
        f"XCODE_VERSION={'.'.join(str(part) for part in version)}",
        f"XCODE_APP={app_path}",
    ])


# --- self test ---------------------------------------------------------------

def self_test() -> int:
    failures: list[str] = []
    cases = 0

    def expect(condition: bool, message: str) -> None:
        nonlocal cases
        cases += 1
        if not condition:
            failures.append(message)

    expect(parse_version("26.4") == (26, 4), "parses a two-part version")
    expect(parse_version("26.4.1") == (26, 4, 1), "parses a three-part version")
    expect(parse_version("26.0 beta") is None, "refuses a non-numeric version")
    expect(parse_version("") is None, "refuses an empty version")

    expect(padded((26, 4)) == (26, 4, 0), "pads a short version")
    expect(padded((26, 4)) < padded((26, 4, 1)), "26.4 sorts below 26.4.1")

    catalogue = [
        ((16, 4), "/Applications/Xcode_16.4.app"),
        ((26, 4), "/Applications/Xcode_26.4.app"),
        ((26, 4, 1), "/Applications/Xcode_26.4.1.app"),
        ((26, 2), "/Applications/Xcode_26.2.app"),
    ]
    version, path = choose(catalogue, (26, 4))
    expect(version == (26, 4, 1) and path.endswith("26.4.1.app"),
           f"picks the newest qualifying Xcode (got {version} {path})")

    version, _ = choose(catalogue, (16, 0))
    expect(version == (26, 4, 1), "a lower floor still picks the newest")

    try:
        choose(catalogue, (27, 0))
        expect(False, "a floor nothing meets must raise")
    except NoUsableXcode as error:
        expect("16.4" in str(error) and "26.4" in str(error),
               "the failure lists what was actually installed")

    try:
        choose([], (26, 4))
        expect(False, "an empty catalogue must raise")
    except NoUsableXcode:
        expect(True, "an empty catalogue raises")

    # A single candidate exactly at the floor is usable.
    version, _ = choose([((26, 4), "/Applications/Xcode.app")], (26, 4))
    expect(version == (26, 4), "the floor itself qualifies")

    rendered = format_environment((26, 4), "/Applications/Xcode_26.4.app")
    expect("DEVELOPER_DIR=/Applications/Xcode_26.4.app/Contents/Developer" in rendered,
           "renders DEVELOPER_DIR")
    expect("XCODE_VERSION=26.4" in rendered, "renders XCODE_VERSION")
    expect(all("=" in line for line in rendered.splitlines()),
           "every rendered line is shell-assignable")

    print(f"select_xcode.py: {cases} self-test cases, {len(failures)} failure(s)")
    for failure in failures:
        print("  FAIL " + failure)
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minimum", default="26.4",
                        help="lowest acceptable Xcode version (default: 26.4)")
    parser.add_argument("--search", default=DEFAULT_SEARCH,
                        help=f"directory to search (default: {DEFAULT_SEARCH})")
    parser.add_argument("--self-test", action="store_true",
                        help="run the built-in test cases and exit")
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()

    minimum = parse_version(arguments.minimum)
    if minimum is None:
        print(f"error: --minimum {arguments.minimum!r} is not a version", file=sys.stderr)
        return 2

    try:
        version, app_path = choose(installed(arguments.search), minimum)
    except NoUsableXcode as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(format_environment(version, app_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())

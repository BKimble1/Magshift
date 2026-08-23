#!/usr/bin/env python3
"""Cross-checks references to the project's own namespace types.

Without a Swift compiler, the single most likely defect in a repository this size
is a reference to a member that does not exist -- `SafetyCopy.compactStatment`,
`A11y.scannerRest`, `Theme.Spacing.mediumm`. Those are trivial for a compiler and
invisible to a linter.

This walks every `static let/var/func`, `case` and nested type declared on the
project's namespace types (including in extensions), then checks every
`Namespace.member` reference in the Swift sources against that set. It also
checks that every accessibility identifier the UI tests look for is one the app
actually sets.

It is a heuristic, not a type checker: it only knows about the namespaces listed
in ``NAMESPACES``, so it cannot produce a false positive from a framework type.

Run: ``python3 Tools/check_symbols.py``
"""

from __future__ import annotations

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftsource  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The project's own namespace-style types: enums and structs whose members are
# referenced as `Type.member` across the codebase.
NAMESPACES = [
    "A11y", "AlgorithmVersion", "AnomalyCluster", "AnomalyStrengthBand", "Branding",
    "CalibrationEngine", "ClusterConfidence", "ClusterEngine", "DetectorConfiguration",
    "DeviceCapabilities", "DeviceMetadata", "DiagnosticsExporter", "DiagnosticsModel",
    "Format", "Log", "MagneticFieldAccuracy", "MagneticFieldAvailability",
    "MagneticFieldSource", "MarkerEntityFactory", "MotionEnergy", "Palette",
    "QualityReason", "RaycastQuality", "RobustStatistics", "RuntimeMode",
    "SafetyCopy", "SampleTimingHealth", "ScanCoding", "ScanExporter", "ScanQualitySummary",
    "ScanQualityVerdict", "ScanRecord", "ScanLoadResult", "SensitivityPreset",
    "SimulatedEnvironment", "SimulatedSpatialProvider", "SpatialSampleBuffer",
    "SystemSettings", "Theme", "TrackingQuality", "Vector3", "WallBounds",
    "WallFrame", "WallMeshBuilder", "WallPoint", "WallVisualStyle",
    "Theme.Spacing", "Theme.Radius", "Theme.Typography",
    "DetectorState", "AnomalyPolarity", "CalibrationRejection", "ARSessionProblem",
    "Fixture", "FakeSpatialProvider",
]

# Members every Swift type gets for free, or that the standard library provides.
BUILTIN_MEMBERS = {
    "self", "Type", "init", "allCases", "rawValue", "RawValue", "description",
    "hashValue", "id", "some", "none",
}

DECL_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public |internal |private |fileprivate |nonisolated\(unsafe\) |nonisolated |static |final |lazy |discardableResult )*"
    r"(?:static\s+)?(?:let|var|func)\s+(`?)(\w+)\1",
    re.MULTILINE,
)
# `[ \t]` rather than `\s`, so a run of `case` lines is not swallowed into one
# greedy match that crosses newlines.
CASE_RE = re.compile(r"^[ \t]*case[ \t]+([\w`, \t]+)", re.MULTILINE)
NESTED_TYPE_RE = re.compile(r"^\s*(?:public |internal |private |static )*"
                            r"(?:struct|enum|class|actor|typealias)\s+(\w+)", re.MULTILINE)

failures: list[str] = []


def swift_sources() -> list[str]:
    return sorted(
        glob.glob(os.path.join(ROOT, "WallField", "**", "*.swift"), recursive=True)
        + glob.glob(os.path.join(ROOT, "WallFieldTests", "**", "*.swift"), recursive=True)
        + glob.glob(os.path.join(ROOT, "WallFieldUITests", "**", "*.swift"), recursive=True)
    )


def body_of(source: str, start: int) -> str:
    """The braced body beginning at or after `start`."""
    open_index = source.find("{", start)
    if open_index == -1:
        return ""
    depth = 0
    for index in range(open_index, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[open_index + 1:index]
    return source[open_index + 1:]


def collect_members(sources: dict[str, str]) -> dict[str, set[str]]:
    members: dict[str, set[str]] = {name: set() for name in NAMESPACES}
    simple = {name.split(".")[-1]: name for name in NAMESPACES if "." not in name}

    for source in sources.values():
        # Declarations and extensions of a namespace type.
        pattern = re.compile(
            r"^\s*(?:@\w+(?:\([^)]*\))?\s*\n?\s*)*"
            r"(?:public |internal |private |final |@MainActor )*"
            r"(?:struct|enum|class|actor|extension)\s+(\w+)",
            re.MULTILINE,
        )
        for match in pattern.finditer(source):
            name = match.group(1)
            if name not in simple:
                continue
            namespace = simple[name]
            body = body_of(source, match.end())
            for decl in DECL_RE.finditer(body):
                members[namespace].add(decl.group(2))
            for case in CASE_RE.finditer(body):
                for token in re.split(r"[,\s]+", case.group(1)):
                    token = token.strip("`")
                    if token:
                        members[namespace].add(token)
            for nested in NESTED_TYPE_RE.finditer(body):
                members[namespace].add(nested.group(1))
                qualified = f"{namespace}.{nested.group(1)}"
                if qualified in members:
                    nested_body = body_of(body, nested.end())
                    for decl in DECL_RE.finditer(nested_body):
                        members[qualified].add(decl.group(2))
                    for case in CASE_RE.finditer(nested_body):
                        for token in re.split(r"[,\s]+", case.group(1)):
                            token = token.strip("`")
                            if token:
                                members[qualified].add(token)
    return members


def check_references(sources: dict[str, str], members: dict[str, set[str]]) -> int:
    checked = 0
    # Longest namespace first so `Theme.Spacing.medium` is not read as `Theme.Spacing`.
    ordered = sorted(NAMESPACES, key=lambda name: -len(name))
    patterns = [(name, re.compile(r"(?<![\w.])" + re.escape(name) + r"\.(\w+)")) for name in ordered]

    for path, source in sources.items():
        relative = os.path.relpath(path, ROOT)
        # Only look at code spans: a namespace name inside a comment or a string
        # is prose, not a reference.
        for span in swiftsource.scan(source):
            if span.kind != "code":
                continue
            consumed: list[tuple[int, int]] = []
            for name, pattern in patterns:
                for match in pattern.finditer(span.text):
                    if any(start <= match.start() < end for start, end in consumed):
                        continue
                    consumed.append((match.start(), match.end()))
                    member = match.group(1)
                    checked += 1
                    if member in BUILTIN_MEMBERS:
                        continue
                    if member not in members[name]:
                        line = span.line + span.text.count("\n", 0, match.start())
                        failures.append(f"{relative}:{line}: {name}.{member} is not declared")
    return checked


def check_ui_test_identifiers(sources: dict[str, str], members: dict[str, set[str]]) -> int:
    """Every identifier the UI tests query must be one the app sets."""
    app_identifiers: set[str] = set()
    for path, source in sources.items():
        if "/WallField/" not in path.replace(os.sep, "/"):
            continue
        for line, literal in swiftsource.string_literals(source):
            _ = line
            text = literal.strip('"')
            if re.fullmatch(r"[a-z][A-Za-z]*(?:\.[A-Za-z]+)+", text):
                app_identifiers.add(text)

    checked = 0
    ui_path = os.path.join(ROOT, "WallFieldUITests")
    for path, source in sources.items():
        if not path.startswith(ui_path):
            continue
        relative = os.path.relpath(path, ROOT)
        for line, literal in swiftsource.string_literals(source):
            text = literal.strip('"')
            if not re.fullmatch(r"[a-z][A-Za-z]*(?:\.[A-Za-z]+)+", text):
                continue
            checked += 1
            if text not in app_identifiers:
                failures.append(
                    f"{relative}:{line}: UI test looks for the accessibility identifier "
                    f"{text!r}, which the app never sets"
                )
    _ = members
    return checked


def main() -> int:
    sources = {}
    for path in swift_sources():
        with open(path, "r", encoding="utf-8") as handle:
            sources[path] = handle.read()

    members = collect_members(sources)
    empty = [name for name, values in members.items() if not values]
    for name in empty:
        failures.append(f"no members found for namespace {name} (is it still called that?)")

    reference_count = check_references(sources, members)
    identifier_count = check_ui_test_identifiers(sources, members)

    print(f"check_symbols.py: {len(NAMESPACES)} namespaces, {reference_count} member "
          f"references, {identifier_count} accessibility identifiers, "
          f"{len(failures)} failure(s)")
    for failure in sorted(set(failures)):
        print("  FAIL " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

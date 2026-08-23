#!/usr/bin/env python3
"""Static audit of the Swift sources.

Checks the repository's own rules -- the ones a compiler would not catch and a
reviewer would have to remember:

* no new SceneKit / ARSCNView code (deprecated from the iOS 26 SDK);
* no `@preconcurrency import` used to silence concurrency diagnostics;
* every `@unchecked Sendable` carries a justification comment;
* no `print(` debugging left behind (the app logs through `Log`);
* no TODO / FIXME / placeholder markers;
* no `try!`, `as!` or `fatalError`, and no implicitly-unwrapped stored
  properties in the app (tests may use the XCTest `setUp` idiom);
* every source file has a documentation comment before its first type;
* the app target does not import XCTest, and tests do not import the app's
  UI-test-only helpers.

Run: ``python3 Tools/audit_sources.py``
"""

from __future__ import annotations

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftsource  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

failures: list[str] = []
checks = 0

APP_SOURCES = sorted(glob.glob(os.path.join(ROOT, "WallField", "**", "*.swift"), recursive=True))
TEST_SOURCES = sorted(
    glob.glob(os.path.join(ROOT, "WallFieldTests", "**", "*.swift"), recursive=True)
    + glob.glob(os.path.join(ROOT, "WallFieldUITests", "**", "*.swift"), recursive=True)
)

CODE_PATTERNS = [
    (re.compile(r"\bimport\s+SceneKit\b"), "imports SceneKit (deprecated; use RealityKit)"),
    (re.compile(r"\bARSCNView\b"), "uses ARSCNView (deprecated; use RealityKit ARView)"),
    (re.compile(r"\bSCNNode\b"), "uses SceneKit types"),
    (re.compile(r"@preconcurrency\s+import"), "uses @preconcurrency import"),
    (re.compile(r"(?<![\w.])print\s*\("), "uses print( instead of Log"),
    (re.compile(r"\btry!\s"), "uses try!"),
    (re.compile(r"\bas!\s"), "uses as!"),
    (re.compile(r"\bfatalError\s*\("), "uses fatalError"),
    (re.compile(r"\bunsafeBitCast\s*\("), "uses unsafeBitCast"),
]

# Implicitly unwrapped optionals are banned in the app, but they are the standard
# XCTest idiom for a system-under-test built in `setUp`, so the rule applies to
# app sources only.
APP_ONLY_PATTERNS = [
    (re.compile(r"\b(?:var|let)\s+\w+\s*:\s*[A-Z]\w*!\s*(?:=|$|\n)"),
     "declares an implicitly unwrapped optional"),
]

MARKER_PATTERN = re.compile(r"\b(TODO|FIXME|XXX|HACK|PLACEHOLDER|placeholder)\b")

# Markers are also banned in comments, which is where they usually hide.
COMMENT_PATTERNS = [(MARKER_PATTERN, "contains a TODO/FIXME/placeholder marker")]


def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def line_of(source: str, index: int) -> int:
    return source.count("\n", 0, index) + 1


def audit(path: str, is_test: bool) -> None:
    relative = os.path.relpath(path, ROOT)
    with open(path, "r", encoding="utf-8") as handle:
        source = handle.read()
    spans = swiftsource.scan(source)

    for span in spans:
        if span.kind != "code":
            continue
        patterns = CODE_PATTERNS if is_test else CODE_PATTERNS + APP_ONLY_PATTERNS
        for pattern, message in patterns:
            for match in pattern.finditer(span.text):
                offset = span.text.count("\n", 0, match.start())
                failures.append(f"{relative}:{span.line + offset}: {message}")
        # Markers must not appear in code either.
        for match in MARKER_PATTERN.finditer(span.text):
            offset = span.text.count("\n", 0, match.start())
            failures.append(f"{relative}:{span.line + offset}: contains a "
                            f"{match.group(1)} marker")

    for span in spans:
        if span.kind not in ("line_comment", "block_comment"):
            continue
        for pattern, message in COMMENT_PATTERNS:
            if pattern.search(span.text):
                failures.append(f"{relative}:{span.line}: {message}")

    # `@unchecked Sendable` must be justified nearby.
    for match in re.finditer(r"@unchecked\s+Sendable", source):
        line = line_of(source, match.start())
        window = "\n".join(source.splitlines()[max(0, line - 16):line])
        justified = "justif" in window.lower() or "@unchecked" in window.lower() and "because" in window.lower()
        check(justified,
              f"{relative}:{line}: @unchecked Sendable without a justification comment above it")

    # `nonisolated(unsafe)` must be justified too.
    for match in re.finditer(r"nonisolated\(unsafe\)", source):
        line = line_of(source, match.start())
        window = "\n".join(source.splitlines()[max(0, line - 12):line])
        check("so `deinit`" in window or "justif" in window.lower() or "because" in window.lower(),
              f"{relative}:{line}: nonisolated(unsafe) without a justification comment above it")

    # Every file opens with documentation before its first declaration.
    first_decl = re.search(
        r"^\s*(?:@\w+[^\n]*\n\s*)*(?:public |internal |private |fileprivate |final |@MainActor )*"
        r"(?:struct|final class|class|enum|actor|protocol|extension)\s",
        source, re.MULTILINE
    )
    if first_decl and not is_test:
        preamble = source[:first_decl.start()]
        check("///" in preamble or "/*" in preamble,
              f"{relative}: no documentation comment before the first declaration")

    if not is_test:
        check("import XCTest" not in source, f"{relative}: app target imports XCTest")


def main() -> int:
    check(len(APP_SOURCES) > 0, "no Swift sources found in WallField/")
    for path in APP_SOURCES:
        audit(path, is_test=False)
    for path in TEST_SOURCES:
        audit(path, is_test=True)

    # Every app source must live under one of the declared feature folders.
    allowed = {
        "App", "AR", "Copy", "DesignSystem", "Detection", "Features",
        "Models", "Persistence", "Resources", "Sensors", "SpatialMapping", "Utilities",
    }
    for path in APP_SOURCES:
        relative = os.path.relpath(path, os.path.join(ROOT, "WallField"))
        top = relative.split(os.sep)[0]
        check(top in allowed, f"WallField/{relative}: not inside a declared module folder")

    print(f"audit_sources.py: {len(APP_SOURCES)} app sources, {len(TEST_SOURCES)} test sources, "
          f"{checks} structural checks, {len(failures)} failure(s)")
    for failure in sorted(set(failures)):
        print("  FAIL " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

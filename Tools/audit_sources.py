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
* the app target does not import XCTest;
* nothing in the app is declared and never used;
* braces, parentheses and brackets balance in every file;
* no class or actor stores a property whose default value references `Self`,
  which Swift rejects as a covariant-`Self` reference.

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

# A stored property with a default value, as opposed to a computed property
# (which has `{` where this has `=`) or a local variable inside a function body.
STORED_PROPERTY_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:private\(set\)|public|internal|private|fileprivate|final|lazy"
    r"|nonisolated\(unsafe\)|nonisolated|weak|unowned)\s+)*"
    r"(?:var|let)\s+\w+\s*(?::[^=]+?)?=\s*(?P<value>.+)$"
)

TYPE_DECLARATION_RE = re.compile(r"\b(class|actor|struct|enum|extension|protocol)\s+\w+")


def mask_non_code(source: str, spans: list) -> str:
    """The source with comments and string literals blanked out.

    Line and column positions are preserved, so a regex can be run over real
    code without a brace inside a string or a keyword inside a comment being
    mistaken for the real thing.
    """
    pieces = []
    for span in spans:
        if span.kind == "code":
            pieces.append(span.text)
        else:
            pieces.append("".join("\n" if ch == "\n" else " " for ch in span.text))
    return "".join(pieces)


def covariant_self_in_stored_property(masked: str) -> list[tuple[int, str]]:
    """Stored properties of a class or actor whose default value mentions `Self`.

    Swift rejects `Self` in a stored property initializer inside a class -- even
    a final one -- with "covariant 'Self' type cannot be referenced from a stored
    property initializer". It is legal in a struct or an enum, and legal anywhere
    inside a function body, so this tracks which kind of declaration opened the
    brace the property sits directly inside.
    """
    findings: list[tuple[int, str]] = []
    # Stack of the declaration keyword that opened each open brace, or None for a
    # brace that opened something else (a function body, a closure, an if).
    stack: list[str | None] = []

    for number, line in enumerate(masked.splitlines(), start=1):
        directly_inside = stack[-1] if stack else None

        if directly_inside in ("class", "actor"):
            match = STORED_PROPERTY_RE.match(line)
            if match and re.search(r"(?<![\w.])Self\s*\.", match.group("value")):
                findings.append((number, line.strip()))

        # Update the stack for braces opened or closed on this line. A line may
        # both open and close braces, so they are processed in order.
        opener: str | None = None
        declaration = TYPE_DECLARATION_RE.search(line)
        if declaration and "{" in line and declaration.start() < line.index("{"):
            opener = declaration.group(1)
        for character in line:
            if character == "{":
                stack.append(opener)
                opener = None
            elif character == "}" and stack:
                stack.pop()

    return findings

DECLARATION_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public |internal |private |fileprivate |final |static |nonisolated\(unsafe\) |lazy "
    r"|mutating |@discardableResult )*"
    r"(?:(?:struct|enum|class|actor|protocol)\s+(\w+)"
    r"|(?:static\s+)?(?:let|var|func)\s+(\w+))",
    re.MULTILINE,
)

# Declarations something other than this repository's own code calls: SwiftUI and
# XCTest entry points, protocol requirements of Apple frameworks, and `@main`.
EXTERNALLY_CALLED = {
    "body", "makeUIView", "updateUIView", "makeCoordinator", "makeUIViewController",
    "updateUIViewController", "init", "deinit", "setUp", "tearDown", "setUpWithError",
    "tearDownWithError", "main", "id", "description", "hashValue", "rawValue",
    "allCases", "errorDescription", "makeIterator", "session", "WallFieldApp",
    "sessionWasInterrupted", "sessionInterruptionEnded",
    "sessionShouldAttemptRelocalization",
}

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

    # Delimiters must balance. Counted over code spans only, so a brace inside a
    # string literal or a comment cannot mask a real imbalance -- which is
    # exactly the failure mode a plain `grep -c` would miss.
    pairs = {"{": "}", "(": ")", "[": "]"}
    closers = {value: key for key, value in pairs.items()}
    stack: list[tuple[str, int]] = []
    unbalanced: str | None = None
    for span in spans:
        if span.kind != "code":
            continue
        line = span.line
        for character in span.text:
            if character == "\n":
                line += 1
            elif character in pairs:
                stack.append((character, line))
            elif character in closers:
                if not stack:
                    unbalanced = unbalanced or f"unexpected '{character}' at line {line}"
                elif stack[-1][0] != closers[character]:
                    opener, opened_at = stack[-1]
                    unbalanced = unbalanced or (
                        f"'{opener}' opened at line {opened_at} closed by "
                        f"'{character}' at line {line}"
                    )
                    stack.pop()
                else:
                    stack.pop()
    if not unbalanced and stack:
        opener, opened_at = stack[0]
        unbalanced = f"'{opener}' opened at line {opened_at} is never closed"
    check(unbalanced is None, f"{relative}: unbalanced delimiters -- {unbalanced}")

    # Swift rejects `Self` in a stored property initializer inside a class.
    masked = mask_non_code(source, spans)
    for line_number, text in covariant_self_in_stored_property(masked):
        check(False,
              f"{relative}:{line_number}: a class stores a property whose default value "
              f"references Self, which Swift rejects -- name the type instead: {text}")


SELF_TEST_CASES: list[tuple[str, str, list[int]]] = [
    ("class stored property with Self is rejected", """
final class A {
    static let x = 1.0
    private(set) var v: Double = Self.x
}
""", [4]),
    ("actor stored property with Self is rejected", """
actor B {
    static let x = 1
    var v = Self.x
}
""", [4]),
    ("struct stored property with Self is legal", """
struct C {
    static let x = 1
    var v = Self.x
}
""", []),
    ("enum computed property with Self is legal", """
enum D {
    static let m = 2
    var ok: Bool { self >= Self.m }
}
""", []),
    ("local variable inside a class method is legal", """
final class E {
    static let s = 1.0
    func go() {
        let v = Self.s * 2
        _ = v
    }
}
""", []),
    ("Self inside a comment or a string is not code", """
final class F {
    // var v = Self.x
    let note = "Self.x"
}
""", []),
    ("nested struct inside a class is legal", """
final class G {
    struct Inner {
        static let x = 1
        var v = Self.x
    }
}
""", []),
    ("computed property on a class is legal", """
final class H {
    static let x = 1
    var v: Int { Self.x }
}
""", []),
]


def self_test() -> int:
    """Checks the covariant-`Self` detector against known-good and known-bad code.

    The negative cases matter as much as the positive one: a check that fires on
    legal struct and enum code would be turned off within a week.
    """
    failures = 0
    for description, source, expected in SELF_TEST_CASES:
        spans = swiftsource.scan(source)
        found = [line for line, _ in covariant_self_in_stored_property(mask_non_code(source, spans))]
        if found != expected:
            print(f"  FAIL {description}: found lines {found}, expected {expected}")
            failures += 1
    print(f"audit_sources.py: {len(SELF_TEST_CASES)} self-test cases, {failures} failure(s)")
    return 1 if failures else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    check(len(APP_SOURCES) > 0, "no Swift sources found in WallField/")
    for path in APP_SOURCES:
        audit(path, is_test=False)
    for path in TEST_SOURCES:
        audit(path, is_test=True)

    # Nothing in the app may be declared and never used.
    #
    # Occurrences are counted over the raw text of every Swift file, strings and
    # comments included, so an identifier used only inside a string
    # interpolation still counts as used.
    raw = ""
    declarations: dict[str, str] = {}
    for path in APP_SOURCES + TEST_SOURCES:
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        raw += source + "\n"
        if path not in APP_SOURCES:
            continue
        relative = os.path.relpath(path, ROOT)
        code_text = "\n".join(
            span.text for span in swiftsource.scan(source) if span.kind == "code"
        )
        for match in DECLARATION_RE.finditer(code_text):
            name = match.group(1) or match.group(2)
            if name and name not in EXTERNALLY_CALLED:
                declarations.setdefault(name, relative)

    for name, relative in sorted(declarations.items()):
        uses = len(re.findall(r"(?<![\w])" + re.escape(name) + r"(?![\w])", raw))
        check(uses > 1, f"{relative}: '{name}' is declared and never used")

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

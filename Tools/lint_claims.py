#!/usr/bin/env python3
"""Enforce WallField's scientific and safety wording rules.

Two classes of rule:

1. **Banned claims.** Phrases the product must never use, anywhere a user could
   read them -- Swift string literals, the Info.plist usage strings, and the
   documentation. These have no legitimate use, so any occurrence fails.

2. **Guarded phrases.** Phrases that are legitimate *only* when negated, such as
   "safe to drill". Each occurrence must sit in a sentence that also contains a
   negation, otherwise it reads as a claim.

Plus two structural rules: a file that shows the "no strong anomaly" headline
must also carry the qualifying sentence, and no user-facing string may describe
a measurement as an object.

Test code and documentation sometimes have to quote the ban list itself. Those
regions opt out explicitly:

    // lint-allow-banned-phrase: begin
    ...
    // lint-allow-banned-phrase: end

and single documentation lines can carry ``lint-allow-banned-phrase`` inline.

Run: ``python3 Tools/lint_claims.py``
"""

from __future__ import annotations

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftsource  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- Rule 1: phrases with no legitimate use ---------------------------------
BANNED = [
    "x-ray", "xray", "x ray",
    "see through the wall", "see through walls", "see-through wall",
    "see inside the wall", "see inside walls",
    "stud finder", "studfinder", "stud detector",
    "metal detector", "wire detector", "cable detector", "pipe detector",
    "live wire detector", "electrical detector",
    "professional-grade", "professional grade",
    "finds hidden wires", "find hidden wires", "find live wires",
    "finds live wires", "locate live wires", "locates wires",
    "detect every", "detects every", "detect all wires", "detect all metal",
    "know where it is safe", "know where it's safe",
    "guaranteed safe", "guarantees safety", "safe to cut",
    "identifies wires", "identify the object", "identifies the object",
]

# --- Rule 2: phrases that must appear negated -------------------------------
GUARDED = [
    "safe to drill",
    "safe to work",
    "live wire",
    "hidden wire",
    "is safe",
    "are safe",
    "clear to drill",
    "all clear",
]

NEGATIONS = [
    "not", "never", "cannot", "can't", "cannot", "no ", "nothing",
    "without", "nor", "unable", "does not", "do not", "don't", "isn't",
    "rather than", "instead of", "prohibited", "must not", "avoid",
]

# --- Rule 3: object-type labels for a measurement ---------------------------
# These words are permitted only in an explicitly disclaiming context, which the
# guarded-phrase machinery already covers for wiring. This rule catches a label
# that *names* the measurement as an object.
OBJECT_LABELS = [
    "wire detected", "screw detected", "stud detected", "pipe detected",
    "nail detected", "metal detected", "cable detected", "rebar detected",
    "found a wire", "found a screw", "found a stud", "found a pipe",
]

SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")

failures: list[str] = []
checked_files = 0
checked_strings = 0


def sentences(text: str) -> list[str]:
    flattened = " ".join(text.split())
    return [s for s in SENTENCE_SPLIT.split(flattened) if s]


def check_text(text: str, where: str) -> None:
    lower = text.lower()
    for phrase in BANNED:
        if phrase in lower:
            failures.append(f"{where}: banned claim {phrase!r}")
    for phrase in OBJECT_LABELS:
        if phrase in lower:
            failures.append(f"{where}: labels a measurement as an object ({phrase!r})")
    for phrase in GUARDED:
        if phrase not in lower:
            continue
        for sentence in sentences(lower):
            if phrase not in sentence:
                continue
            if not any(negation in sentence for negation in NEGATIONS):
                failures.append(
                    f"{where}: {phrase!r} appears without a negation in "
                    f"\"{sentence.strip()[:110]}\""
                )


ALLOW_BEGIN = "lint-allow-banned-phrase: begin"
ALLOW_END = "lint-allow-banned-phrase: end"


def allowed_line_ranges(source: str) -> list[tuple[int, int]]:
    """1-based [start, end] line ranges that opt out of the banned-phrase rules."""
    ranges: list[tuple[int, int]] = []
    start: int | None = None
    for number, line in enumerate(source.splitlines(), start=1):
        if ALLOW_BEGIN in line:
            start = number
        elif ALLOW_END in line and start is not None:
            ranges.append((start, number))
            start = None
    if start is not None:
        ranges.append((start, len(source.splitlines())))
    return ranges


def swift_files() -> list[str]:
    return sorted(
        glob.glob(os.path.join(ROOT, "WallField", "**", "*.swift"), recursive=True)
        + glob.glob(os.path.join(ROOT, "WallFieldTests", "**", "*.swift"), recursive=True)
        + glob.glob(os.path.join(ROOT, "WallFieldUITests", "**", "*.swift"), recursive=True)
    )


def main() -> int:
    global checked_files, checked_strings

    for path in swift_files():
        checked_files += 1
        relative = os.path.relpath(path, ROOT)
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()

        allowed = allowed_line_ranges(source)
        for line, literal in swiftsource.string_literals(source):
            if any(start <= line <= end for start, end in allowed):
                continue
            checked_strings += 1
            check_text(literal, f"{relative}:{line}")

        # Structural rule: the "no strong anomaly" headline never travels alone.
        if "noAnomalyHeadline" in source:
            carries_qualifier = (
                "noAnomalySubtitle" in source
                or "NoAnomalyStatement" in source
            )
            if not carries_qualifier:
                failures.append(
                    f"{relative}: uses SafetyCopy.noAnomalyHeadline without the qualifying "
                    "sentence (noAnomalySubtitle) or the NoAnomalyStatement component"
                )

    # Info.plist usage strings.
    import plistlib
    plist_path = os.path.join(ROOT, "Config", "WallField-Info.plist")
    with open(plist_path, "rb") as handle:
        plist = plistlib.load(handle)
    for key, value in plist.items():
        if isinstance(value, str) and key.startswith("NS") and key.endswith("UsageDescription"):
            checked_strings += 1
            check_text(value, f"Config/WallField-Info.plist:{key}")

    # Documentation.
    for path in sorted(glob.glob(os.path.join(ROOT, "Docs", "*.md"))
                       + glob.glob(os.path.join(ROOT, "*.md"))):
        relative = os.path.relpath(path, ROOT)
        with open(path, "r", encoding="utf-8") as handle:
            body = handle.read()
        checked_files += 1
        # Documentation quotes the banned list itself in APP_STORE_PREP; those
        # lines are explicitly marked so the linter can skip them.
        kept = [
            line for line in body.splitlines()
            if "lint-allow-banned-phrase" not in line
        ]
        check_text("\n".join(kept), relative)

    print(f"lint_claims.py: {checked_files} files, {checked_strings} strings, "
          f"{len(failures)} failure(s)")
    for failure in failures:
        print("  FAIL " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

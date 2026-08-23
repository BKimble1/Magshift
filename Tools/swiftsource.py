#!/usr/bin/env python3
"""Minimal Swift lexer: splits a source file into code, comments and string
literals so the auditors can reason about each separately.

It is not a parser. It knows just enough about Swift's lexical structure --
line comments, nested block comments, string literals, multiline string
literals, raw strings and interpolation -- to answer "is this byte inside a
string?" reliably, which regexes alone cannot.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Span:
    kind: str          # "code" | "line_comment" | "block_comment" | "string"
    text: str
    line: int          # 1-based line the span starts on


def scan(source: str) -> list[Span]:
    spans: list[Span] = []
    i = 0
    n = len(source)
    line = 1
    buffer_start = 0

    def flush_code(end: int, start_line: int) -> None:
        if end > buffer_start:
            spans.append(Span("code", source[buffer_start:end], start_line))

    code_line = line
    while i < n:
        ch = source[i]

        if ch == "\n":
            line += 1
            i += 1
            continue

        # Line comment
        if source.startswith("//", i):
            flush_code(i, code_line)
            end = source.find("\n", i)
            end = n if end == -1 else end
            spans.append(Span("line_comment", source[i:end], line))
            i = end
            buffer_start = i
            code_line = line
            continue

        # Block comment (nesting allowed in Swift)
        if source.startswith("/*", i):
            flush_code(i, code_line)
            depth = 0
            start = i
            start_line = line
            while i < n:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                    if depth == 0:
                        break
                else:
                    if source[i] == "\n":
                        line += 1
                    i += 1
            spans.append(Span("block_comment", source[start:i], start_line))
            buffer_start = i
            code_line = line
            continue

        # Raw string delimiters
        if ch == "#":
            hashes = 0
            j = i
            while j < n and source[j] == "#":
                hashes += 1
                j += 1
            if j < n and source[j] == '"':
                flush_code(i, code_line)
                i, line = _consume_string(source, j, line, hashes)
                spans.append(Span("string", source[buffer_start:i], line))
                buffer_start = i
                code_line = line
                continue

        if ch == '"':
            flush_code(i, code_line)
            start = i
            start_line = line
            i, line = _consume_string(source, i, line, 0)
            spans.append(Span("string", source[start:i], start_line))
            buffer_start = i
            code_line = line
            continue

        i += 1

    flush_code(n, code_line)
    return spans


def _consume_string(source: str, i: int, line: int, hashes: int) -> tuple[int, int]:
    """Consumes a string literal starting at the opening quote. Returns the
    index just past the closing delimiter and the updated line number."""
    n = len(source)
    hash_suffix = "#" * hashes
    triple = source.startswith('"""', i)
    if triple:
        i += 3
        terminator = '"""' + hash_suffix
    else:
        i += 1
        terminator = '"' + hash_suffix

    escape = "\\" + hash_suffix
    while i < n:
        if source.startswith(escape, i):
            # Skip the escape and whatever it escapes. Interpolation is skipped
            # crudely by consuming to the matching parenthesis.
            i += len(escape)
            if i < n and source[i] == "(":
                depth = 0
                while i < n:
                    if source[i] == "(":
                        depth += 1
                    elif source[i] == ")":
                        depth -= 1
                        if depth == 0:
                            i += 1
                            break
                    elif source[i] == "\n":
                        line += 1
                    i += 1
            elif i < n:
                if source[i] == "\n":
                    line += 1
                i += 1
            continue
        if source.startswith(terminator, i):
            return i + len(terminator), line
        if not triple and source[i] == "\n":
            # Unterminated single-line string; stop at the newline rather than
            # swallowing the rest of the file.
            return i, line
        if source[i] == "\n":
            line += 1
        i += 1
    return n, line


def string_literals(source: str) -> list[tuple[int, str]]:
    """Every string literal's (line, raw text including delimiters)."""
    return [(s.line, s.text) for s in scan(source) if s.kind == "string"]


def code_only(source: str) -> list[tuple[int, str]]:
    """Every code span's (line, text), with comments and strings removed."""
    return [(s.line, s.text) for s in scan(source) if s.kind == "code"]

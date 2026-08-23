#!/usr/bin/env python3
"""A small, dependency-free parser for the NeXTSTEP-style plist that Xcode uses
for ``project.pbxproj``.

Only what ``Tools/validate_project.py`` needs is implemented: dictionaries,
arrays, bare and quoted strings, and both comment styles.
"""

from __future__ import annotations

BARE_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$./-@:<>~*+")


class ParseError(Exception):
    pass


class Parser:
    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0

    # -- low level --------------------------------------------------------
    def error(self, message: str) -> ParseError:
        line = self.text.count("\n", 0, self.pos) + 1
        return ParseError(f"{message} at line {line}")

    def skip_trivia(self) -> None:
        text, n = self.text, len(self.text)
        while self.pos < n:
            ch = text[self.pos]
            if ch in " \t\r\n":
                self.pos += 1
            elif text.startswith("/*", self.pos):
                end = text.find("*/", self.pos + 2)
                if end == -1:
                    raise self.error("unterminated block comment")
                self.pos = end + 2
            elif text.startswith("//", self.pos):
                end = text.find("\n", self.pos)
                self.pos = n if end == -1 else end + 1
            else:
                return

    def expect(self, ch: str) -> None:
        self.skip_trivia()
        if self.pos >= len(self.text) or self.text[self.pos] != ch:
            raise self.error(f"expected {ch!r}")
        self.pos += 1

    # -- values -----------------------------------------------------------
    def parse_value(self):
        self.skip_trivia()
        if self.pos >= len(self.text):
            raise self.error("unexpected end of input")
        ch = self.text[self.pos]
        if ch == "{":
            return self.parse_dict()
        if ch == "(":
            return self.parse_array()
        if ch == '"':
            return self.parse_quoted()
        return self.parse_bare()

    def parse_dict(self) -> dict:
        self.expect("{")
        result: dict[str, object] = {}
        while True:
            self.skip_trivia()
            if self.pos < len(self.text) and self.text[self.pos] == "}":
                self.pos += 1
                return result
            key = self.parse_value()
            if not isinstance(key, str):
                raise self.error("dictionary key must be a string")
            self.expect("=")
            result[key] = self.parse_value()
            self.expect(";")

    def parse_array(self) -> list:
        self.expect("(")
        result: list[object] = []
        while True:
            self.skip_trivia()
            if self.pos < len(self.text) and self.text[self.pos] == ")":
                self.pos += 1
                return result
            result.append(self.parse_value())
            self.skip_trivia()
            if self.pos < len(self.text) and self.text[self.pos] == ",":
                self.pos += 1

    def parse_quoted(self) -> str:
        self.pos += 1  # opening quote
        chunks: list[str] = []
        while True:
            if self.pos >= len(self.text):
                raise self.error("unterminated quoted string")
            ch = self.text[self.pos]
            if ch == "\\":
                nxt = self.text[self.pos + 1]
                chunks.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
                self.pos += 2
            elif ch == '"':
                self.pos += 1
                return "".join(chunks)
            else:
                chunks.append(ch)
                self.pos += 1

    def parse_bare(self) -> str:
        start = self.pos
        while self.pos < len(self.text) and self.text[self.pos] in BARE_CHARS:
            self.pos += 1
        if self.pos == start:
            raise self.error(f"unexpected character {self.text[self.pos]!r}")
        return self.text[start:self.pos]


def loads(text: str) -> dict:
    if text.startswith("// !$*UTF8*$!"):
        text = text.split("\n", 1)[1]
    parser = Parser(text)
    value = parser.parse_value()
    parser.skip_trivia()
    if parser.pos != len(parser.text):
        raise parser.error("trailing content after root object")
    if not isinstance(value, dict):
        raise ParseError("root object is not a dictionary")
    return value


def load(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return loads(handle.read())

#!/usr/bin/env python3
"""Choose a build number that App Store Connect will accept.

A build number has to be unique and increasing for a given marketing version.
A CI counter satisfies that on its own only while every upload comes from that
one CI. The moment a build is uploaded from anywhere else -- a second CI, a
developer's Xcode -- the counter is behind, and the upload is rejected at the
very end of a long, signed build.

So this asks App Store Connect what it already holds and prints whichever is
higher: one past that, or the caller's fallback.

    python3 Tools/appstore_build_number.py \\
        --bundle-id com.idlery.magshift --fallback 17 \\
        --key-id ABCD1234 --issuer-id 1234-... --key-path AuthKey_ABCD1234.p8

**It never fails the build.** Every error -- no credentials, no network, no app
record yet, a missing dependency -- prints the fallback and exits 0, with the
reason on stderr. The fallback is already a valid build number; refusing to
release because a *nice-to-have* lookup failed would be the wrong trade.

Needs `cryptography` for the ES256 token when credentials are supplied. Without
it, the fallback is used. Everything else is standard library.

    python3 Tools/appstore_build_number.py --self-test   # no network required
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_ROOT = "https://api.appstoreconnect.apple.com"
AUDIENCE = "appstoreconnect-v1"
TOKEN_LIFETIME = 900          # 15 minutes; Apple rejects tokens longer than 20
REQUEST_TIMEOUT = 20


class LookupUnavailable(RuntimeError):
    """The query could not be made or answered. Never fatal to the caller."""


# --- number choosing ---------------------------------------------------------

def numeric(value: object) -> int | None:
    """`"41"` -> 41. `None` for anything that is not a whole number.

    App Store Connect reports build numbers as strings, and a project is free
    to use `1.2.3` there. This only understands the integers this project uses.
    """
    text = str(value).strip()
    if not text.isdigit():
        return None
    return int(text)


def highest(versions: list[object]) -> int | None:
    """The largest whole-number build version in `versions`, or `None`."""
    numbers = [number for number in (numeric(item) for item in versions) if number is not None]
    return max(numbers) if numbers else None


def choose(latest: int | None, fallback: int) -> int:
    """One past what App Store Connect holds, or the fallback if that is higher."""
    if latest is None:
        return fallback
    return max(latest + 1, fallback)


# --- App Store Connect token -------------------------------------------------

def base64url(payload: bytes) -> str:
    return base64.urlsafe_b64encode(payload).rstrip(b"=").decode("ascii")


def raw_signature(r: int, s: int) -> bytes:
    """JWS wants ECDSA as raw R||S, 32 bytes each. `cryptography` returns DER."""
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


@contextlib.contextmanager
def quiet_stderr():
    """Silence file descriptor 2 for the duration of the block.

    A half-installed `cryptography` prints a Rust panic and a backtrace straight
    to fd 2, below Python's reach, before anything catchable happens. The
    failure is reported properly by the caller, so that noise is worse than
    useless: it makes a handled condition look like a crash.
    """
    sys.stderr.flush()
    saved = os.dup(2)
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, 2)
        yield
    finally:
        sys.stderr.flush()
        os.dup2(saved, 2)
        os.close(devnull)
        os.close(saved)


def load_crypto():
    """Import `cryptography`, turning *any* failure into `LookupUnavailable`.

    `BaseException` rather than `Exception` on purpose. A broken native
    extension does not politely raise `ImportError`: a `cryptography` whose
    `_cffi_backend` is missing raises a Rust `PanicException`, which is not an
    `Exception` at all. This script's whole contract is that it never fails the
    build, and a half-installed dependency is precisely the case that contract
    exists for.
    """
    try:
        with quiet_stderr():
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import ec
            from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as error:  # noqa: BLE001 - see the docstring
        raise LookupUnavailable(
            f"the `cryptography` package is unavailable or broken ({error!r}), "
            "so no App Store Connect token can be signed"
        ) from error
    return hashes, serialization, ec, decode_dss_signature


def make_token(key_id: str, issuer_id: str, private_key_pem: str, issued_at: int) -> str:
    hashes, serialization, ec, decode_dss_signature = load_crypto()

    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": issued_at,
        "exp": issued_at + TOKEN_LIFETIME,
        "aud": AUDIENCE,
    }
    signing_input = ".".join([
        base64url(json.dumps(header, separators=(",", ":")).encode()),
        base64url(json.dumps(payload, separators=(",", ":")).encode()),
    ]).encode("ascii")

    try:
        key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
        der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as error:  # noqa: BLE001 - any key problem is the same outcome
        raise LookupUnavailable(f"the private key could not be used: {error}") from error

    return f"{signing_input.decode('ascii')}.{base64url(raw_signature(*decode_dss_signature(der)))}"


# --- App Store Connect queries -----------------------------------------------

def get(path: str, query: dict[str, str], token: str) -> dict:
    url = f"{API_ROOT}{path}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise LookupUnavailable(f"{path} returned HTTP {error.code}") from error
    except Exception as error:  # noqa: BLE001 - network, DNS, TLS, JSON: same outcome
        raise LookupUnavailable(f"{path} could not be reached: {error}") from error


def latest_build_number(bundle_id: str, token: str) -> int | None:
    """The highest build number App Store Connect holds, or `None` if there are none."""
    apps = get("/v1/apps", {"filter[bundleId]": bundle_id, "limit": "1"}, token)
    records = apps.get("data") or []
    if not records:
        raise LookupUnavailable(
            f"App Store Connect has no app record for {bundle_id}. "
            "Create one before the first upload; see Docs/RELEASE_TO_TESTFLIGHT.md."
        )
    app_id = records[0].get("id")

    builds = get(
        "/v1/builds",
        {"filter[app]": str(app_id), "limit": "200", "sort": "-version"},
        token,
    )
    return highest([
        (record.get("attributes") or {}).get("version")
        for record in (builds.get("data") or [])
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

    expect(numeric("41") == 41, "parses a plain build number")
    expect(numeric(41) == 41, "parses an integer build number")
    expect(numeric(" 41 ") == 41, "tolerates surrounding whitespace")
    expect(numeric("1.2.3") is None, "refuses a dotted build number")
    expect(numeric("") is None, "refuses an empty build number")
    expect(numeric(None) is None, "refuses a missing build number")

    expect(highest(["3", "41", "7"]) == 41, "takes the largest, not the last")
    expect(highest(["3", "1.0", "7"]) == 7, "skips build numbers it cannot read")
    expect(highest([]) is None, "no builds means no highest")
    expect(highest(["1.0"]) is None, "only unreadable builds means no highest")

    expect(choose(None, 5) == 5, "no builds yet falls back to the caller's number")
    expect(choose(41, 5) == 42, "goes one past what App Store Connect holds")
    expect(choose(3, 90) == 90, "keeps the fallback when it is already higher")
    expect(choose(90, 90) == 91, "never repeats a number already uploaded")
    expect(choose(0, 1) == 1, "handles a zero build number")

    expect(base64url(b"\x00\xff") == "AP8", "base64url strips padding")
    expect("=" not in base64url(b"abcd"), "base64url is unpadded")

    signature = raw_signature(1, 2)
    expect(len(signature) == 64, "a JWS signature is 64 raw bytes")
    expect(signature[:32] == (1).to_bytes(32, "big"), "R is the first 32 bytes")
    expect(signature[32:] == (2).to_bytes(32, "big"), "S is the last 32 bytes")

    # Anything that stops a token being signed -- an unreadable key, a missing
    # or half-installed `cryptography` -- must surface as LookupUnavailable, so
    # the caller falls back instead of failing the build.
    try:
        make_token("KEY", "ISSUER", "not a pem", 0)
        expect(False, "an unusable key must raise LookupUnavailable")
    except LookupUnavailable:
        expect(True, "an unusable key raises LookupUnavailable")
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as error:  # noqa: BLE001
        expect(False, f"an unusable key raised {type(error).__name__}, not LookupUnavailable")

    print(f"appstore_build_number.py: {cases} self-test cases, {len(failures)} failure(s)")
    for failure in failures:
        print("  FAIL " + failure)
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", help="the app's bundle identifier")
    parser.add_argument("--fallback", type=int,
                        help="build number to use when the lookup cannot be made")
    parser.add_argument("--key-id", default="", help="App Store Connect API key ID")
    parser.add_argument("--issuer-id", default="", help="App Store Connect issuer ID")
    parser.add_argument("--key-path", default="", help="path to the .p8 private key")
    parser.add_argument("--self-test", action="store_true",
                        help="run the built-in test cases and exit")
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()

    if arguments.fallback is None or not arguments.bundle_id:
        parser.error("--bundle-id and --fallback are required")

    fallback = arguments.fallback
    try:
        if not (arguments.key_id and arguments.issuer_id and arguments.key_path):
            raise LookupUnavailable("no App Store Connect credentials were supplied")
        with open(arguments.key_path, "r", encoding="utf-8") as handle:
            private_key = handle.read()
        token = make_token(arguments.key_id, arguments.issuer_id, private_key, int(time.time()))
        latest = latest_build_number(arguments.bundle_id, token)
    except LookupUnavailable as error:
        print(f"appstore_build_number.py: {error}", file=sys.stderr)
        print(f"appstore_build_number.py: using the fallback, {fallback}", file=sys.stderr)
        print(fallback)
        return 0
    except OSError as error:
        print(f"appstore_build_number.py: {error}", file=sys.stderr)
        print(fallback)
        return 0

    chosen = choose(latest, fallback)
    print(
        f"appstore_build_number.py: App Store Connect holds "
        f"{'no builds' if latest is None else latest}; using {chosen}",
        file=sys.stderr,
    )
    print(chosen)
    return 0


if __name__ == "__main__":
    sys.exit(main())

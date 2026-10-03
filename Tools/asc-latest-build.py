#!/usr/bin/env python3
"""Prints the highest build number App Store Connect already holds for the app.

    Tools/asc-latest-build.py com.rrochlin.LiftingCoach
    Tools/asc-latest-build.py --marketing com.rrochlin.LiftingCoach

`--marketing` prints the highest *marketing version* instead (`0.2.0`), or
`0.0.0` when there is none — `testflight.sh` uses it to make every upload
decide whether it's a new release (see the versioning note there).

Prints 0 when the app exists but has no builds. Exits non-zero, with the reason
on stderr, for anything else — a missing key, an unregistered bundle id, an API
error. `Tools/testflight.sh` runs this before archiving so a build number that
can't be uploaded fails in seconds rather than after a full archive.

Why this exists: the build number is `git rev-list --count HEAD`, which counts
the history of the branch you're on, not of the repository. Two branches can
reach the same count with different code, and an upload from a branch that is
*behind* another can carry a lower number than one already shipped. Asking App
Store Connect is the only check that knows what has actually been uploaded.

Read-only: it lists builds and changes nothing. Standard library plus two
binaries every Mac has: `openssl`, because App Store Connect wants an
ES256-signed token and the standard library has no ECDSA; and `curl`, because
it trusts the system keychain. `urllib` trusts whatever certificate bundle the
installed Python was given, and the python.org build ships with none until
someone runs its "Install Certificates" step — which this machine's hadn't. Credentials come from the same place
`testflight.sh` uses: ASC_KEY_ID and ASC_ISSUER_ID in the environment, the key
at ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

API = "https://api.appstoreconnect.apple.com"


def fail(message: str) -> None:
    print(f"asc-latest-build: {message}", file=sys.stderr)
    sys.exit(1)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(signature: bytes) -> bytes:
    """ECDSA-Sig-Value (DER) to the 64-byte r||s that JWS ES256 requires.

    `openssl dgst -sign` emits DER: SEQUENCE { INTEGER r, INTEGER s }. Each
    integer may carry a leading zero byte (to stay positive) or be shorter than
    32 bytes, so both are normalised to exactly 32. Getting this wrong produces
    a token App Store Connect rejects as NOT_AUTHORIZED, which reads like a
    credential problem rather than an encoding one.
    """
    if signature[0] != 0x30:
        fail("unexpected signature encoding from openssl")
    index = 2 if signature[1] < 0x80 else 2 + (signature[1] & 0x7F)
    parts = []
    for _ in range(2):
        if signature[index] != 0x02:
            fail("unexpected signature encoding from openssl")
        length = signature[index + 1]
        value = signature[index + 2 : index + 2 + length]
        parts.append(value.lstrip(b"\x00").rjust(32, b"\x00"))
        index += 2 + length
    return parts[0] + parts[1]


def token(key_id: str, issuer: str, key_path: Path) -> str:
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = b64url(
        json.dumps(
            {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
        ).encode()
    )
    signing_input = f"{header}.{claims}".encode()
    signed = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=signing_input,
        capture_output=True,
        check=False,
    )
    if signed.returncode != 0:
        fail(f"openssl could not sign with {key_path}: {signed.stderr.decode().strip()}")
    return f"{header}.{claims}.{b64url(der_to_raw(signed.stdout))}"


def get(url: str, bearer: str) -> dict:
    # The token goes in on stdin (`--header @-`) rather than as an argument, so
    # it never appears in the process list. It's short-lived, but it is a
    # bearer credential for the whole App Store Connect account.
    result = subprocess.run(
        ["curl", "--silent", "--show-error", "--header", "@-",
         "--write-out", "\n%{http_code}", url],
        input=f"Authorization: Bearer {bearer}\n".encode(),
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        fail(f"could not reach App Store Connect: {result.stderr.decode().strip()}")
    body, _, status = result.stdout.decode().rpartition("\n")
    if status != "200":
        fail(f"App Store Connect returned {status}: {body[:300]}")
    return json.loads(body)


def main() -> None:
    args = sys.argv[1:]
    marketing = "--marketing" in args
    args = [a for a in args if a != "--marketing"]
    if len(args) != 1:
        fail("usage: asc-latest-build.py [--marketing] <bundle-id>")
    bundle_id = args[0]

    key_id = os.environ.get("ASC_KEY_ID", "")
    issuer = os.environ.get("ASC_ISSUER_ID", "")
    if not key_id or not issuer:
        fail("ASC_KEY_ID and ASC_ISSUER_ID must be set")
    key_path = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8"
    if not key_path.is_file():
        fail(f"no key at {key_path}")

    bearer = token(key_id, issuer, key_path)

    query = urllib.parse.urlencode({"filter[bundleId]": bundle_id, "fields[apps]": "bundleId"})
    apps = get(f"{API}/v1/apps?{query}", bearer)["data"]
    if not apps:
        fail(f"no app registered in App Store Connect for {bundle_id}")
    app_id = apps[0]["id"]

    if marketing:
        print(highest_marketing_version(app_id, bearer))
        return

    # Every build of the app, across marketing versions, paged. The maximum is
    # taken numerically: build numbers are strings in the API, and "99" sorts
    # above "102" as text.
    query = urllib.parse.urlencode(
        {"filter[app]": app_id, "fields[builds]": "version", "limit": 200}
    )
    url: str | None = f"{API}/v1/builds?{query}"
    highest = 0
    while url:
        page = get(url, bearer)
        for build in page["data"]:
            version = build["attributes"]["version"]
            if version.isdigit():
                highest = max(highest, int(version))
        url = page.get("links", {}).get("next")

    print(highest)


def highest_marketing_version(app_id: str, bearer: str) -> str:
    """The highest `CFBundleShortVersionString` any build was uploaded under.

    TestFlight files builds under a *pre-release version* per marketing
    version, so this lists those. Compared as integers per component — as
    text, "0.10.0" would sort below "0.9.0".
    """
    query = urllib.parse.urlencode(
        {"filter[app]": app_id, "fields[preReleaseVersions]": "version", "limit": 200}
    )
    url: str | None = f"{API}/v1/preReleaseVersions?{query}"
    best: tuple[int, ...] = (0, 0, 0)
    while url:
        page = get(url, bearer)
        for entry in page["data"]:
            parts = entry["attributes"]["version"].split(".")
            if all(p.isdigit() for p in parts):
                best = max(best, tuple(int(p) for p in parts))
        url = page.get("links", {}).get("next")
    return ".".join(str(p) for p in best)


if __name__ == "__main__":
    main()

"""The error codes are a contract with the phone, so they're pinned to it."""

from __future__ import annotations

import re

from conftest import REPO_ROOT

from liftcoach_server import errors

BACKEND_CLIENT_SWIFT = REPO_ROOT / "Sources/App/Backend/BackendClient.swift"

#: Codes this service raises that the app switches on. The rest —
#: `unauthenticated`, `malformedRequest` — describe requests a correct build
#: never makes, and the app has no case for them by design.
SHARED_WITH_THE_APP = {
    errors.SignedInElsewhere.code,
    errors.UnsupportedSchemaVersion.code,
}


def test_the_shared_codes_exist_in_backend_error() -> None:
    """`BackendError`'s case names are the wire vocabulary.

    Renaming one in Swift without renaming it here would leave the phone
    showing a generic failure for a refusal it has real words for — which
    looks like an outage rather than "you signed in on your other phone."
    """
    source = BACKEND_CLIENT_SWIFT.read_text()
    cases = set(re.findall(r"^\s*case (\w+)", source, flags=re.MULTILINE))

    assert cases, f"no enum cases parsed out of {BACKEND_CLIENT_SWIFT}"
    assert SHARED_WITH_THE_APP <= cases


def test_a_refusal_carries_its_status_and_its_detail() -> None:
    error = errors.SignedInElsewhere("nope", heldBy="the new one")
    assert error.status == 409
    assert error.as_body() == {
        "error": "signedInElsewhere",
        "message": "nope",
        "heldBy": "the new one",
    }

"""Fakes for the three seams, and the event shapes API Gateway sends.

Nothing here mocks boto3. Every protocol in this package is narrow enough to
implement honestly in a few lines, which is the point of them being narrow —
a test that patched a client would be asserting what boto3 was called with
rather than what this service decided.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from liftcoach_server import handlers  # noqa: E402
from liftcoach_server.lease import InMemoryLeaseStore  # noqa: E402
from liftcoach_server.snapshots import InMemoryMetaStore  # noqa: E402

#: The repo this package lives in, used by the tests that pin a Python copy of
#: something Swift owns.
REPO_ROOT = Path(__file__).resolve().parents[2]


class FakeObjects:
    """An S3 that records what it was asked to sign."""

    def __init__(self) -> None:
        self.puts: list[dict[str, object]] = []
        self.gets: list[str] = []
        #: What a later HEAD will report, keyed by object key. A test that
        #: exercises the indexer sets this to whatever the presign recorded,
        #: which is exactly what S3 would do.
        self.stored_metadata: dict[str, dict[str, str]] = {}

    def presign_put(
        self,
        key: str,
        metadata: dict[str, str],
        checksum_sha256: str,
        expires_in: int,
    ) -> str:
        self.puts.append(
            {
                "key": key,
                "metadata": metadata,
                "checksum": checksum_sha256,
                "expires_in": expires_in,
            }
        )
        self.stored_metadata[key] = dict(metadata)
        return f"https://s3.example/{key}?signed=put"

    def presign_get(self, key: str, expires_in: int) -> str:
        self.gets.append(key)
        return f"https://s3.example/{key}?signed=get"

    def head_metadata(self, key: str) -> dict[str, str]:
        return dict(self.stored_metadata.get(key, {}))


@pytest.fixture
def deps() -> handlers.Deps:
    installed = handlers.Deps(
        objects=FakeObjects(),
        leases=InMemoryLeaseStore(),
        meta=InMemoryMetaStore(),
    )
    handlers.configure(installed)
    yield installed
    handlers.configure(None)


def request(subject: str | None = "sub-abc", **body: object) -> dict[str, object]:
    """An API Gateway proxy event with a validated identity on it.

    `subject=None` is the shape of a request that reached a handler without
    passing an authorizer — which shouldn't be reachable, and is tested anyway
    because "shouldn't be reachable" is how the interesting ones start.
    """
    event: dict[str, object] = {"body": json.dumps(body)}
    if subject is not None:
        event["requestContext"] = {"authorizer": {"jwt": {"claims": {"sub": subject}}}}
    return event


def body_of(response: dict[str, object]) -> dict[str, object]:
    return json.loads(str(response["body"]))


#: A real SHA-256, so the checksum conversion is exercised rather than stubbed.
SHA = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

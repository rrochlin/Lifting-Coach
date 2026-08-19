"""The one test here that uses real boto3, because the claim needs it.

Everything else in this suite runs against `FakeObjects`, which is right for
testing decisions. But "the metadata is signed, so the phone cannot lie about
it" is not a decision this code makes — it's a property of what botocore
produces, and a fake asserting it would only be asserting that the fake agrees
with the docstring.

It found a real bug on the first run: boto3's default presigner emitted a
**SigV2** URL, which carries metadata as query parameters rather than signed
headers. Under that signature a phone could PUT the right bytes under any
schema version it liked, and every sentence in `snapshots.py` about the stamp
riding on the object would have been false. `S3Objects` now pins `s3v4`.

No network and no credentials: presigning is local arithmetic over a key, so
fake credentials sign fine and nothing is ever sent.
"""

from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import pytest
from conftest import SHA

from liftcoach_server import snapshots
from liftcoach_server.aws import S3Objects
from liftcoach_server.schema import SchemaVerdict


@pytest.fixture
def credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "AKIAEXAMPLE")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "secret")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")


@pytest.fixture
def ticket(credentials: None) -> snapshots.UploadTicket:
    return snapshots.prepare_upload(
        S3Objects("liftcoach-snapshots-test"),
        subject="sub-abc",
        verdict=SchemaVerdict("v14_cognitoSub", False),
        sha256_hex=SHA,
        row_counts={"workout": 840},
        device_id="phone-1",
    )


def test_the_url_is_signed_with_sigv4(ticket: snapshots.UploadTicket) -> None:
    query = parse_qs(urlparse(ticket.url).query)
    assert query["X-Amz-Algorithm"] == ["AWS4-HMAC-SHA256"]


def test_every_header_the_phone_is_told_to_send_is_covered_by_the_signature(
    ticket: snapshots.UploadTicket,
) -> None:
    """The load-bearing assertion. If a header the ticket names isn't in
    `SignedHeaders`, the phone can change it and S3 will accept the PUT — which
    is exactly the hole SigV2 left open."""
    query = parse_qs(urlparse(ticket.url).query)
    signed = set(query["X-Amz-SignedHeaders"][0].split(";"))

    for name in ticket.headers:
        assert name.lower() in signed, f"{name} is not covered by the signature"


def test_the_schema_stamp_and_the_digest_are_both_signed(
    ticket: snapshots.UploadTicket,
) -> None:
    query = parse_qs(urlparse(ticket.url).query)
    signed = set(query["X-Amz-SignedHeaders"][0].split(";"))

    assert "x-amz-meta-schema-version" in signed
    assert "x-amz-checksum-sha256" in signed


def test_the_url_points_at_this_account_only(ticket: snapshots.UploadTicket) -> None:
    assert urlparse(ticket.url).path == "/users/sub-abc/snapshot.sqlite.gz"

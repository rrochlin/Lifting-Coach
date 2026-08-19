"""Keys, signed metadata, and reading an object's own account of itself."""

from __future__ import annotations

import base64
import json

import pytest
from conftest import SHA, FakeObjects

from liftcoach_server import snapshots
from liftcoach_server.errors import MalformedRequest
from liftcoach_server.schema import SchemaVerdict

V14 = SchemaVerdict(version="v14_cognitoSub", newer_than_server=False)


def test_a_snapshot_lives_under_its_own_subject() -> None:
    assert snapshots.object_key("sub-abc") == "users/sub-abc/snapshot.sqlite.gz"


def test_the_subject_is_recoverable_from_the_key() -> None:
    """The S3 event carries a key and nothing else, so the prefix is the only
    identity available at index time."""
    key = snapshots.object_key("sub-abc")
    assert snapshots.subject_from_key(key) == "sub-abc"


def test_a_foreign_key_is_not_read_as_a_subject() -> None:
    with pytest.raises(MalformedRequest):
        snapshots.subject_from_key("something/else.gz")


def test_the_digest_is_converted_for_s3() -> None:
    """Hex is what a human reads in a log; base64 is what the checksum header
    takes. The phone never does this conversion — it replays whole headers."""
    encoded = snapshots.hex_to_base64_sha256(SHA)
    assert base64.b64decode(encoded).hex() == SHA


def test_a_digest_that_is_not_a_digest_is_refused() -> None:
    with pytest.raises(MalformedRequest):
        snapshots.hex_to_base64_sha256("nonsense")
    with pytest.raises(MalformedRequest):
        snapshots.hex_to_base64_sha256("abcd")


def test_the_ticket_names_every_header_the_phone_must_send() -> None:
    """The signature covers these, so a PUT missing one is rejected by S3. The
    phone gets the exact set rather than the rules for building it."""
    objects = FakeObjects()
    ticket = snapshots.prepare_upload(
        objects,
        subject="sub-abc",
        verdict=V14,
        sha256_hex=SHA,
        row_counts={"workout": 840, "workoutSet": 14520},
        device_id="phone-1",
    )

    signed = objects.puts[0]["metadata"]
    assert isinstance(signed, dict)
    for name, value in signed.items():
        assert ticket.headers[f"x-amz-meta-{name}"] == value

    assert ticket.headers["x-amz-checksum-sha256"] == objects.puts[0]["checksum"]
    assert ticket.headers["Content-Type"] == snapshots.CONTENT_TYPE


def test_the_stamp_rides_on_the_object() -> None:
    objects = FakeObjects()
    snapshots.prepare_upload(
        objects,
        subject="sub-abc",
        verdict=V14,
        sha256_hex=SHA,
        row_counts={"workout": 840},
        device_id="phone-1",
    )
    metadata = objects.puts[0]["metadata"]
    assert isinstance(metadata, dict)
    assert metadata["schema-version"] == "v14_cognitoSub"
    assert metadata["sha256"] == SHA
    assert metadata["device-id"] == "phone-1"
    assert json.loads(metadata["row-counts"]) == {"workout": 840}
    assert "newer-than-server" not in metadata


def test_a_newer_schema_is_marked_on_the_object() -> None:
    """On the object rather than only in the table, so a reader that doesn't
    understand the schema can tell without consulting something a different
    deploy may have written."""
    objects = FakeObjects()
    snapshots.prepare_upload(
        objects,
        subject="sub-abc",
        verdict=SchemaVerdict(version="v99_future", newer_than_server=True),
        sha256_hex=SHA,
        row_counts={},
        device_id="phone-1",
    )
    assert objects.puts[0]["metadata"]["newer-than-server"] == "true"


def test_absurd_row_counts_are_dropped_not_fatal() -> None:
    """S3 caps user metadata at 2 KB. Row counts are a consistency aid, and
    losing one must never be a reason a training log fails to upload."""
    objects = FakeObjects()
    huge = {f"table_{n}": n for n in range(500)}
    snapshots.prepare_upload(
        objects,
        subject="sub-abc",
        verdict=V14,
        sha256_hex=SHA,
        row_counts=huge,
        device_id="phone-1",
    )
    metadata = objects.puts[0]["metadata"]
    assert "row-counts" not in metadata
    assert metadata["schema-version"] == "v14_cognitoSub"


def test_meta_is_read_back_off_the_object() -> None:
    meta = snapshots.meta_from_object(
        subject="sub-abc",
        key="users/sub-abc/snapshot.sqlite.gz",
        etag='"d41d8cd98f00b204e9800998ecf8427e"',
        byte_count=1_270_000,
        metadata={
            "schema-version": "v14_cognitoSub",
            "sha256": SHA,
            "device-id": "phone-1",
            "row-counts": json.dumps({"workout": 840}),
            "uploaded-at": "2026-08-19T12:00:00+00:00",
        },
    )
    assert meta.etag == "d41d8cd98f00b204e9800998ecf8427e"  # quotes stripped
    assert meta.row_counts == {"workout": 840}
    assert meta.as_body()["schemaVersion"] == "v14_cognitoSub"


def test_unreadable_row_counts_do_not_sink_the_record() -> None:
    """The counts help notice "the upload succeeded but the file is wrong".
    Failing to index an object S3 already checksummed, because an aid was
    malformed, would trade a real record for a missing one."""
    meta = snapshots.meta_from_object(
        subject="sub-abc",
        key="users/sub-abc/snapshot.sqlite.gz",
        etag="abc",
        byte_count=10,
        metadata={"schema-version": "v14_cognitoSub", "row-counts": "{not json"},
    )
    assert meta.row_counts == {}
    assert meta.schema_version == "v14_cognitoSub"

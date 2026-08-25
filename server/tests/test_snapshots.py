"""Keys, and the record built from what a file turned out to contain."""

from __future__ import annotations

import pytest

from liftcoach_server.errors import MalformedKey
from liftcoach_server.inspection import SnapshotContents
from liftcoach_server.schema import SchemaVerdict
from liftcoach_server.snapshots import (
    InMemoryMetaStore,
    SnapshotMeta,
    object_key,
    subject_from_key,
)


def test_the_key_is_scoped_to_one_account() -> None:
    assert object_key("sub-abc") == "users/sub-abc/snapshot.sqlite.gz"


def test_the_key_and_the_iam_policy_have_to_agree() -> None:
    """The phone's role scopes `s3:PutObject` to `users/${aws:PrincipalTag/sub}/*`.
    A key shape that didn't start `users/{sub}/` wouldn't be a naming
    disagreement — nothing would upload at all."""
    assert object_key("sub-abc").startswith("users/sub-abc/")


def test_the_subject_round_trips() -> None:
    assert subject_from_key(object_key("sub-abc")) == "sub-abc"


@pytest.mark.parametrize("key", ["", "snapshot.sqlite.gz", "users//snapshot.sqlite.gz", "other/x/y"])
def test_a_key_that_names_no_account_is_refused(key: str) -> None:
    with pytest.raises(MalformedKey):
        subject_from_key(key)


def contents(version: str = "v14_cognitoSub", newer: bool = False) -> SnapshotContents:
    return SnapshotContents(
        schema=SchemaVerdict(version=version, newer_than_server=newer),
        row_counts={"workout": 840},
    )


def test_a_described_snapshot_carries_what_was_read() -> None:
    meta = SnapshotMeta.describing(
        subject="sub-abc",
        key=object_key("sub-abc"),
        version_id="v1",
        etag='"abc123"',
        byte_count=2048,
        uploaded_at="2026-08-21T10:00:00.000Z",
        contents=contents(),
    )

    assert meta.schema_version == "v14_cognitoSub"
    assert meta.row_counts == {"workout": 840}
    assert meta.readable


def test_the_etag_loses_the_quotes_s3_wraps_it_in() -> None:
    """S3 reports `"abc123"`, quotes included. Storing them means every later
    comparison has to remember to strip them, and one of them won't."""
    meta = SnapshotMeta.describing(
        subject="sub-abc",
        key="users/sub-abc/snapshot.sqlite.gz",
        version_id="v1",
        etag='"abc123"',
        byte_count=1,
        uploaded_at="",
        contents=contents(),
    )
    assert meta.etag == "abc123"


def test_an_unreadable_record_still_says_what_arrived() -> None:
    """Size, etag and time come from the event and are known even when the
    bytes are nonsense — which is what makes the record useful for working out
    what went wrong."""
    meta = SnapshotMeta.unreadable(
        subject="sub-abc",
        key=object_key("sub-abc"),
        version_id="v1",
        etag='"abc123"',
        byte_count=17,
        uploaded_at="2026-08-21T10:00:00.000Z",
        problem="The object is not readable gzip",
    )

    assert not meta.readable
    assert meta.problem
    assert meta.byte_count == 17
    assert meta.schema_version == ""
    assert meta.row_counts == {}


def test_the_store_holds_one_item_per_account() -> None:
    store = InMemoryMetaStore()
    assert store.read("sub-abc") is None

    for count in (1, 2):
        store.write(
            SnapshotMeta.describing(
                subject="sub-abc",
                key=object_key("sub-abc"),
                version_id=f"v{count}",
                etag="e",
                byte_count=count,
                uploaded_at="",
                contents=contents(),
            )
        )

    assert store.read("sub-abc").version_id == "v2"

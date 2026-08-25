"""The one module that touches boto3, tested at its own seam.

Nothing here reaches AWS. `DynamoMetaStore` takes its resource as a constructor
argument, so a fake table is enough to exercise the only branch in that module
that makes a decision — which exception means "I lost a race" and which means
"something is actually wrong."

That distinction is worth a test rather than a comment: both arrive as
`ClientError`, they differ only by a string in the response, and getting it
wrong in the permissive direction means a genuine `AccessDenied` is swallowed
as a lost race and the index goes silently unwritten. Silent is the bad
direction — an index that stops being written while every invocation reports
success is precisely the failure this service is supposed to make impossible.
"""

from __future__ import annotations

import pytest
from botocore.exceptions import ClientError

from liftcoach_server.aws import DynamoMetaStore
from liftcoach_server.snapshots import SnapshotMeta


def client_error(code: str) -> ClientError:
    return ClientError({"Error": {"Code": code, "Message": code}}, "PutItem")


class FakeTable:
    """Records what it was asked to write, or raises what it was told to."""

    def __init__(self, raises: ClientError | None = None) -> None:
        self.raises = raises
        self.calls: list[dict[str, object]] = []

    def put_item(self, **kwargs: object) -> None:
        self.calls.append(kwargs)
        if self.raises is not None:
            raise self.raises


class FakeResource:
    def __init__(self, table: FakeTable) -> None:
        self._table = table

    def Table(self, name: str) -> FakeTable:  # noqa: N802 - boto3's spelling
        return self._table


def meta(uploaded_at: str = "2026-08-21T10:00:00.000Z") -> SnapshotMeta:
    return SnapshotMeta(
        subject="sub-abc",
        key="users/sub-abc/snapshot.sqlite.gz",
        version_id="v1",
        etag="abc123",
        byte_count=2048,
        uploaded_at=uploaded_at,
    )


def store(table: FakeTable) -> DynamoMetaStore:
    return DynamoMetaStore("lift-coach-prod-snapshot-meta", resource=FakeResource(table))


def test_a_lost_race_returns_normally() -> None:
    """A newer upload is already indexed. This invocation did its job."""
    table = FakeTable(raises=client_error("ConditionalCheckFailedException"))

    store(table).write(meta())  # must not raise


def test_access_denied_is_not_mistaken_for_a_lost_race() -> None:
    """The failure mode the two exceptions share a type with.

    A missing `dynamodb:PutItem` grant must reach S3 as a failed invocation, so
    it retries and eventually surfaces. Swallowing it would leave every
    invocation reporting success with nothing ever written.
    """
    table = FakeTable(raises=client_error("AccessDeniedException"))

    with pytest.raises(ClientError):
        store(table).write(meta())


def test_throttling_is_not_mistaken_for_a_lost_race() -> None:
    """The transient case, which is the one a retry actually fixes."""
    table = FakeTable(raises=client_error("ProvisionedThroughputExceededException"))

    with pytest.raises(ClientError):
        store(table).write(meta())


def test_the_write_is_conditional_on_the_stored_timestamp() -> None:
    """Guards the guard.

    The ordering rule is proved through `InMemoryMetaStore` elsewhere, which
    can't notice if the real store stopped sending the condition at all. This
    asserts the expression is on the call and reads the timestamp it should.
    """
    table = FakeTable()

    store(table).write(meta(uploaded_at="2026-08-21T11:30:00.000Z"))

    call = table.calls[0]
    assert call["ConditionExpression"] == (
        "attribute_not_exists(pk) OR uploadedAt <= :uploadedAt"
    )
    assert call["ExpressionAttributeValues"] == {":uploadedAt": "2026-08-21T11:30:00.000Z"}
    assert call["Item"]["pk"] == "USER#sub-abc"

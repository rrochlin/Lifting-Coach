"""Where a snapshot lives, and the record of what one turned out to be.

The phone writes `users/{sub}/snapshot.sqlite.gz` directly, using temporary AWS
credentials from a Cognito identity pool whose role is scoped to that prefix by
a principal tag carrying the user pool `sub`. Nothing in this package issues a
URL or authorises a request any more — IAM does that, ahead of any code running.

What's left is the read side: **the index.** One item per user, saying what the
bucket holds without anyone downloading it, so a coach can answer "as of when?"
(Tenet 10) and a phase 2.3 query tool can decline a question about a schema it
doesn't understand.

**Every field in that record that matters is derived from the object, not
reported by the uploader.** `schema_version`, `newer_than_server` and
`row_counts` come out of `inspection.inspect`, which opens the file. The two
fields that can't be derived — which device sent it, and when — are copied from
the object's own metadata and are marked in the item as what they are:
advisory, useful in a log, and not something anything decides on.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

from .errors import MalformedKey
from .inspection import SnapshotContents

#: The one object per account. The prefix is not a convention — the phone's IAM
#: policy scopes `s3:PutObject` to `users/${aws:PrincipalTag/sub}/*`, so this
#: string and that policy have to agree or nothing uploads at all.
SNAPSHOT_FILENAME = "snapshot.sqlite.gz"


def object_key(subject: str) -> str:
    """Where this account's snapshot lives."""
    return f"users/{subject}/{SNAPSHOT_FILENAME}"


def subject_from_key(key: str) -> str:
    """Recovers whose snapshot an object is, from where it sits.

    The S3 event carries a key and nothing else, so the prefix is the only
    identity available at index time. That's sound because the prefix is not
    something a caller chose: the credentials that wrote the object could only
    reach one prefix, and which one was decided by Cognito from a validated
    token. Trusting it here is trusting IAM, not the uploader.
    """
    parts = key.split("/")
    if len(parts) < 3 or parts[0] != "users" or not parts[1]:
        raise MalformedKey(f"Not a snapshot key: {key!r}")
    return parts[1]


@dataclass(frozen=True)
class SnapshotMeta:
    """The `snapshotMeta` item: what the server holds, without the file."""

    subject: str
    key: str
    #: The S3 version this record describes. Not decoration — on a versioned
    #: bucket a bare read returns whatever is current, so without pinning to
    #: the version the event named, two uploads a minute apart can produce a
    #: record whose contents come from one object and whose etag and size come
    #: from another.
    version_id: str
    etag: str
    byte_count: int
    uploaded_at: str

    #: Derived, by opening the file.
    schema_version: str = ""
    newer_than_server: bool = False
    unrecognized_migrations: tuple[str, ...] = ()
    row_counts: dict[str, int] = field(default_factory=dict)

    #: False when the object could not be opened. The reason travels with it,
    #: because "there is a file and it is wrong" is a different state from
    #: "there is no file" and a coach should be able to tell them apart.
    readable: bool = True
    problem: str = ""

    #: Copied from the object's own user metadata. Advisory: the phone sets it
    #: with its own credentials and nothing verifies it. It exists so a log can
    #: say which handset produced a bad file.
    device_id: str = ""

    @classmethod
    def describing(
        cls,
        subject: str,
        key: str,
        version_id: str,
        etag: str,
        byte_count: int,
        uploaded_at: str,
        contents: SnapshotContents,
        device_id: str = "",
    ) -> SnapshotMeta:
        """A record of an object that opened cleanly."""
        return cls(
            subject=subject,
            key=key,
            version_id=version_id,
            etag=etag.strip('"'),
            byte_count=byte_count,
            uploaded_at=uploaded_at,
            schema_version=contents.schema.version,
            newer_than_server=contents.schema.newer_than_server,
            unrecognized_migrations=contents.schema.unrecognized,
            row_counts=dict(contents.row_counts),
            readable=True,
            device_id=device_id,
        )

    @classmethod
    def unreadable(
        cls,
        subject: str,
        key: str,
        version_id: str,
        etag: str,
        byte_count: int,
        uploaded_at: str,
        problem: str,
        device_id: str = "",
    ) -> SnapshotMeta:
        """A record of an object that didn't.

        Deliberately still a record. Leaving the index untouched would make a
        known-bad upload indistinguishable from one that never happened, and
        the second reads as "nothing to worry about."
        """
        return cls(
            subject=subject,
            key=key,
            version_id=version_id,
            etag=etag.strip('"'),
            byte_count=byte_count,
            uploaded_at=uploaded_at,
            readable=False,
            problem=problem,
            device_id=device_id,
        )

    def as_body(self) -> dict[str, object]:
        """The `SnapshotDescriptor` shape, for whatever reads this later."""
        return {
            "etag": self.etag,
            "schemaVersion": self.schema_version,
            "byteCount": self.byte_count,
            "uploadedAt": self.uploaded_at,
            "rowCounts": self.row_counts,
            "readable": self.readable,
        }


class MetaStore(Protocol):
    """Where `snapshotMeta` items live. `aws.DynamoMetaStore` is the real one."""

    def read(self, subject: str) -> SnapshotMeta | None: ...

    def write(self, meta: SnapshotMeta) -> None: ...


class InMemoryMetaStore:
    """A metadata store for tests and local runs."""

    def __init__(self) -> None:
        self._items: dict[str, SnapshotMeta] = {}

    def read(self, subject: str) -> SnapshotMeta | None:
        return self._items.get(subject)

    def write(self, meta: SnapshotMeta) -> None:
        self._items[meta.subject] = meta

"""The Lambda entry point. There is one.

The phone uploads to S3 directly with credentials scoped by its Cognito
identity, so there is no request to authorise, no body to parse and no status
code to choose. What remains is a consequence of an object existing:
`ObjectCreated` fires, and this records what arrived.

**That's why there is no commit call.** A phone that dies between the PUT and a
report is ordinary on a cellular link, and a design where that leaves the index
disagreeing with the bucket is a design that needs a reconciler. Here the object
*is* the trigger.
"""

from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from . import snapshots
from .errors import UnreadableSnapshot
from .inspection import inspect
from .snapshots import MetaStore, SnapshotMeta

Event = dict[str, Any]


class SnapshotObjects(Protocol):
    """The bucket, as this service uses it: read one object, exactly."""

    def download(self, key: str, version_id: str, destination: Path) -> None: ...

    def metadata(self, key: str, version_id: str) -> dict[str, str]: ...


@dataclass
class Deps:
    """What the handler needs, resolved once per container.

    Built from the environment on first use and replaceable by a test. This is
    `AppEnvironment` on the device side: the composition root is one object, so
    a handler never constructs a client and a test never patches a module.
    """

    objects: SnapshotObjects
    meta: MetaStore


_deps: Deps | None = None


def configure(deps: Deps | None) -> None:
    """Installs the dependencies, or clears them so the next call rebuilds."""
    global _deps
    _deps = deps


def dependencies() -> Deps:
    global _deps
    if _deps is None:
        # Imported lazily so the rest of this module — and every test of it —
        # runs without boto3 present or credentials configured.
        from .aws import build_dependencies

        _deps = build_dependencies(
            bucket=os.environ["SNAPSHOT_BUCKET"],
            meta_table=os.environ["SNAPSHOT_META_TABLE"],
        )
    return _deps


def index_snapshot(event: Event, context: Any = None) -> dict[str, Any]:
    """S3 `ObjectCreated` — records what the bucket now holds.

    Records are handled one at a time and anything unexpected re-raises, so S3
    retries the batch. Writing an item is idempotent — same key, same derived
    content — so a redelivered record costs a duplicate write and nothing else.

    The one failure that does *not* re-raise is `UnreadableSnapshot`: see
    `errors.py` for why a file that cannot be opened is recorded rather than
    retried.
    """
    deps = dependencies()
    indexed = 0
    unreadable = 0

    for record in event.get("Records", []):
        detail = record.get("s3", {})
        obj = detail.get("object", {})
        key = str(obj.get("key", ""))
        if not key.endswith(snapshots.SNAPSHOT_FILENAME):
            # Something else landed in the bucket. Not this function's object,
            # and not an error worth failing a batch over.
            continue

        # **Pinned to the version the event names.** On a versioned bucket a
        # bare read returns the current object, so two uploads inside the same
        # minute — a finished workout and a plan save, which is ordinary —
        # would have this event read the *next* upload's bytes and file them
        # against this one's etag and size. The result is a record that is
        # internally inconsistent with nothing to indicate it.
        version_id = str(obj.get("versionId", ""))

        if _index_one(
            deps,
            key=key,
            version_id=version_id,
            etag=str(obj.get("eTag", "")),
            byte_count=int(obj.get("size", 0)),
            uploaded_at=str(record.get("eventTime", "")),
        ):
            indexed += 1
        else:
            unreadable += 1

    return {"indexed": indexed, "unreadable": unreadable}


def _index_one(
    deps: Deps,
    key: str,
    version_id: str,
    etag: str,
    byte_count: int,
    uploaded_at: str,
) -> bool:
    subject = snapshots.subject_from_key(key)
    device_id = deps.objects.metadata(key, version_id).get("device-id", "")

    with tempfile.TemporaryDirectory() as scratch:
        archive = Path(scratch) / snapshots.SNAPSHOT_FILENAME
        deps.objects.download(key, version_id, archive)

        try:
            contents = inspect(archive)
        except UnreadableSnapshot as problem:
            deps.meta.write(
                SnapshotMeta.unreadable(
                    subject=subject,
                    key=key,
                    version_id=version_id,
                    etag=etag,
                    byte_count=byte_count,
                    uploaded_at=uploaded_at,
                    problem=problem.message,
                    device_id=device_id,
                )
            )
            return False

    deps.meta.write(
        SnapshotMeta.describing(
            subject=subject,
            key=key,
            version_id=version_id,
            etag=etag,
            byte_count=byte_count,
            uploaded_at=uploaded_at,
            contents=contents,
            device_id=device_id,
        )
    )
    return True

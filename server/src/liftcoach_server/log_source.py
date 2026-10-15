"""Where the coach's log tools get the lifter's snapshot from (INFRA-SPEC §14).

The current object at `users/{sub}/snapshot.sqlite.gz`, decompressed into
`/tmp` and **cached by its etag**: a Lambda container answering several
messages in a conversation fetches the file once, and a new upload — a new
etag — is fetched the next time it's asked for. Fetched lazily, on the first
log tool call of a turn, so a message that never touches the log never reads
S3.

**Whose file is decided by the verified `sub`**, from Cognito's `GetUser` on
the access token (`accounts.py`), never by anything in the request. The coach
role can read every user's prefix; this code reads exactly one.

**The schema is checked before anything is read.** A snapshot carrying a
migration this deploy doesn't know is marked unreadable, and the tools say so
rather than run queries against tables that may have moved (`log_tools.py`).
"""

from __future__ import annotations

import gzip
import shutil
import sqlite3
import tempfile
from pathlib import Path
from typing import Any, Protocol

from . import schema
from .log_tools import LogSnapshot
from .snapshots import object_key


class SnapshotSource(Protocol):
    def fetch(self, subject: str) -> LogSnapshot | None:
        """The lifter's current snapshot, or `None` if they've never uploaded."""
        ...


def describe(path: Path, uploaded_at: str) -> LogSnapshot:
    """Opens a decompressed snapshot just far enough to check its schema."""
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            applied = [row[0] for row in connection.execute("SELECT identifier FROM grdb_migrations")]
        finally:
            connection.close()
        verdict = schema.resolve(applied)
    except Exception as error:  # an unreadable file, or no migrations at all
        return LogSnapshot(path=str(path), uploaded_at=uploaded_at, readable=False, problem=str(error))
    if verdict.newer_than_server:
        return LogSnapshot(
            path=str(path), uploaded_at=uploaded_at, readable=False,
            problem=f"unrecognised migrations: {', '.join(verdict.unrecognized)}",
        )
    return LogSnapshot(path=str(path), uploaded_at=uploaded_at, readable=True)


class S3SnapshotSource:
    """Reads the current snapshot object. `s3:GetObject` on `users/*` and
    `kms:Decrypt` on the bucket key — read only, like the indexer's role."""

    def __init__(self, bucket: str, cache: Path | None = None, client: Any | None = None) -> None:
        self._bucket = bucket
        self._cache = cache or Path(tempfile.gettempdir()) / "coach-snapshots"
        self._client = client

    @property
    def client(self) -> Any:
        if self._client is None:
            import boto3

            self._client = boto3.client("s3")
        return self._client

    def fetch(self, subject: str) -> LogSnapshot | None:
        from botocore.exceptions import ClientError

        key = object_key(subject)
        try:
            head = self.client.head_object(Bucket=self._bucket, Key=key)
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
                return None
            raise
        etag = str(head.get("ETag", "")).strip('"')
        modified = head.get("LastModified")
        uploaded_at = modified.strftime("%Y-%m-%d %H:%M:%S.000") if modified else ""

        self._cache.mkdir(parents=True, exist_ok=True)
        path = self._cache / f"{subject}-{etag}.sqlite"
        if not path.exists():
            # Older copies of this lifter's file go; /tmp is 512 MB.
            for stale in self._cache.glob(f"{subject}-*.sqlite"):
                stale.unlink(missing_ok=True)
            partial = path.with_suffix(".partial")
            # Pinned to the etag just read, so the bytes match what was checked.
            body = self.client.get_object(Bucket=self._bucket, Key=key, IfMatch=f'"{etag}"')["Body"]
            with gzip.open(body, "rb") as source, partial.open("wb") as sink:
                shutil.copyfileobj(source, sink, length=64 * 1024)
            partial.rename(path)
        return describe(path, uploaded_at)


class LocalSnapshotSource:
    """A snapshot already on disk — tests and local runs."""

    def __init__(self, path: Path | None, uploaded_at: str = "2026-10-15 05:19:56.000") -> None:
        self._path = path
        self._uploaded_at = uploaded_at
        self.fetches = 0

    def fetch(self, subject: str) -> LogSnapshot | None:
        self.fetches += 1
        if self._path is None:
            return None
        return describe(self._path, self._uploaded_at)

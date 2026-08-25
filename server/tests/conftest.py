"""Fakes for the two seams, and a real snapshot to feed them.

Nothing here mocks boto3. Both protocols in this package are narrow enough to
implement honestly in a few lines, which is the point of them being narrow — a
test that patched a client would be asserting what boto3 was called with rather
than what this service decided.

The snapshot builder is deliberately *not* a fake. Since the redesign, what the
indexer records comes from opening the file, so a test that handed it a
pre-baked answer would be testing nothing at all. These build a real gzipped
SQLite database with a real `grdb_migrations` table.
"""

from __future__ import annotations

import gzip
import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from liftcoach_server import handlers, schema  # noqa: E402
from liftcoach_server.snapshots import InMemoryMetaStore, object_key  # noqa: E402

#: The repo this package lives in, used by the test that pins a Python copy of
#: something Swift owns.
REPO_ROOT = Path(__file__).resolve().parents[2]


def build_snapshot(
    path: Path,
    migrations: tuple[str, ...] = schema.KNOWN_MIGRATIONS,
    workouts: int = 3,
) -> Path:
    """Writes a gzipped SQLite file shaped like a real snapshot.

    Only the parts the indexer reads are real: `grdb_migrations`, and enough
    user tables to count. That's the whole surface — this service never looks
    at a column of training data, which is worth noticing as a property rather
    than only as a convenience here.
    """
    raw = path.with_suffix(".sqlite")
    connection = sqlite3.connect(raw)
    with connection:
        connection.execute("CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        connection.executemany(
            "INSERT INTO grdb_migrations (identifier) VALUES (?)",
            [(identifier,) for identifier in migrations],
        )
        connection.execute("CREATE TABLE workout (id TEXT PRIMARY KEY)")
        connection.execute("CREATE TABLE exercise (id TEXT PRIMARY KEY)")
        connection.executemany(
            "INSERT INTO workout (id) VALUES (?)", [(str(n),) for n in range(workouts)]
        )
    connection.close()

    with raw.open("rb") as source, gzip.open(path, "wb") as sink:
        sink.write(source.read())
    raw.unlink()
    return path


class FakeObjects:
    """A bucket holding bytes, and the metadata that came with them.

    Keyed by `(key, version_id)` rather than by key alone, so a test can put
    two versions of an object in and prove the indexer reads the one the event
    named. That distinction is the whole reason `version_id` is threaded
    through, so a fake that collapsed it would quietly make the bug untestable.
    """

    def __init__(self) -> None:
        self.objects: dict[tuple[str, str], bytes] = {}
        self.stored_metadata: dict[tuple[str, str], dict[str, str]] = {}
        self.downloads: list[tuple[str, str]] = []

    def put(
        self,
        key: str,
        body: bytes,
        version_id: str = "v1",
        metadata: dict[str, str] | None = None,
    ) -> None:
        self.objects[(key, version_id)] = body
        self.stored_metadata[(key, version_id)] = dict(metadata or {})

    def download(self, key: str, version_id: str, destination: Path) -> None:
        self.downloads.append((key, version_id))
        destination.write_bytes(self.objects[(key, version_id)])

    def metadata(self, key: str, version_id: str) -> dict[str, str]:
        return dict(self.stored_metadata.get((key, version_id), {}))


@pytest.fixture
def objects() -> FakeObjects:
    return FakeObjects()


@pytest.fixture
def deps(objects: FakeObjects) -> handlers.Deps:
    installed = handlers.Deps(objects=objects, meta=InMemoryMetaStore())
    handlers.configure(installed)
    yield installed
    handlers.configure(None)


def event_for(
    subject: str = "sub-abc",
    version_id: str = "v1",
    etag: str = '"abc123"',
    size: int = 2048,
    event_time: str = "2026-08-21T10:00:00.000Z",
    key: str | None = None,
) -> dict[str, object]:
    """One S3 `ObjectCreated` record, shaped as S3 sends it."""
    return {
        "Records": [
            {
                "eventTime": event_time,
                "s3": {
                    "object": {
                        "key": key if key is not None else object_key(subject),
                        "versionId": version_id,
                        "eTag": etag,
                        "size": size,
                    }
                },
            }
        ]
    }

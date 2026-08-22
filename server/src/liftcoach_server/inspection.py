"""Opens a snapshot and reports what is actually in it.

This module is what replaced a signature. The earlier design had the server
mint a presigned PUT with the schema version and row counts baked into the
SigV4 signature, so S3 would reject an upload whose headers didn't match — the
phone could not misreport what it was sending. That machinery is gone with the
presigning, and the property it protected is now obtained the direct way:
**download the file and look.**

That is strictly the stronger claim. A signature proved the phone said the same
thing twice; this proves what the bytes contain. It also removes the only
realistic failure mode the signature ever addressed — there is one user and no
adversary here, so the risk was never a lying phone, it was a phone that
computed its own stamp wrongly.

It is the same discipline `ExerciseStatsStore` follows on the device, applied
to the bucket instead of the log: a derived record with exactly one writer can
be *stale*, but it cannot disagree with the thing it describes, and rebuilding
it is always a valid repair.
"""

from __future__ import annotations

import gzip
import sqlite3
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from .errors import UnreadableSnapshot
from .schema import SchemaVerdict, resolve

#: A five-year log is ~10 MB uncompressed and the vendored catalog is ~1.5 MB of
#: that. This is a sanity bound, not a quota: it exists so a wrong or hostile
#: object cannot fill the Lambda's 512 MB `/tmp` before anything looks at it.
MAX_UNCOMPRESSED_BYTES = 256 * 1024 * 1024


@dataclass(frozen=True)
class SnapshotContents:
    """What the file turned out to be."""

    schema: SchemaVerdict
    row_counts: dict[str, int] = field(default_factory=dict)


def inspect(archive: Path) -> SnapshotContents:
    """Reads a gzipped snapshot, or says why it can't.

    Every failure it can distinguish is raised as `UnreadableSnapshot`, because
    the caller's decision is the same for all of them: record it and stop.
    Retrying a file that isn't a database will not produce a database.
    """
    with tempfile.TemporaryDirectory() as scratch:
        database = Path(scratch) / "snapshot.sqlite"
        _decompress(archive, database)
        return _describe(database)


def _decompress(archive: Path, destination: Path) -> None:
    try:
        with gzip.open(archive, "rb") as source, destination.open("wb") as sink:
            # Copied in chunks with a ceiling rather than read whole: a gzip
            # member can claim a very small compressed size and expand
            # arbitrarily, and this runs on a function with a fixed /tmp.
            written = 0
            while chunk := source.read(1024 * 1024):
                written += len(chunk)
                if written > MAX_UNCOMPRESSED_BYTES:
                    raise UnreadableSnapshot(
                        "The archive expands past the size any snapshot should be."
                    )
                sink.write(chunk)
    except UnreadableSnapshot:
        raise
    except (OSError, EOFError, gzip.BadGzipFile) as exc:
        # A truncated upload lands here, which is the common real case: the
        # phone lost the connection partway through a PUT that S3 nonetheless
        # completed as a shorter object.
        raise UnreadableSnapshot(f"The object is not readable gzip: {exc}") from exc


def _describe(database: Path) -> SnapshotContents:
    # Opened read-only through a URI, for the same reason `SnapshotExporter`
    # does it: a writable open would let SQLite create a journal beside the
    # file and, worse, would invite something to migrate a snapshot on the way
    # past and report a version it was never written at.
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        applied = _applied_migrations(connection)
        return SnapshotContents(schema=resolve(applied), row_counts=_row_counts(connection))
    finally:
        connection.close()


def _applied_migrations(connection: sqlite3.Connection) -> list[str]:
    try:
        rows = connection.execute("SELECT identifier FROM grdb_migrations").fetchall()
    except sqlite3.DatabaseError as exc:
        # `sqlite3.connect` succeeds on any file at all — it doesn't touch the
        # disk until a statement runs — so this is where "that isn't a
        # database" is actually discovered, and where a database that is one
        # but isn't *ours* is discovered too.
        raise UnreadableSnapshot(f"Not a Lifting Coach database: {exc}") from exc
    return [str(row[0]) for row in rows]


def _row_counts(connection: sqlite3.Connection) -> dict[str, int]:
    """One count per user table.

    The same query `SnapshotExporter.describe` runs on the way out, so the two
    numbers are comparable — which is the point of recording them at all. A
    count the server derived that disagrees with the count the phone reported
    means the file in the bucket is not the file the phone thinks it sent.
    """
    tables = [
        str(row[0])
        for row in connection.execute(
            """
            SELECT name FROM sqlite_master
            WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%'
              AND name NOT LIKE 'grdb_%'
            ORDER BY name
            """
        ).fetchall()
    ]

    counts: dict[str, int] = {}
    for table in tables:
        # A table name can't be a bound parameter, so it's quoted the way the
        # Swift side quotes it. These names come from `sqlite_master` in a file
        # we are about to read anyway, so this is hygiene rather than a
        # boundary — but an unquoted identifier would break on a table named
        # after a keyword long before anyone got clever with it.
        quoted = '"' + table.replace('"', '""') + '"'
        counts[table] = int(connection.execute(f"SELECT COUNT(*) FROM {quoted}").fetchone()[0])
    return counts


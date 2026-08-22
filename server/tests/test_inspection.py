"""Opening a real file and reporting what's in it.

Every test here builds an actual gzipped SQLite database. That's not
thoroughness for its own sake — since the redesign, "what the server knows
about a snapshot" is defined as "what opening it says," so a test that stubbed
the opening would assert nothing.
"""

from __future__ import annotations

import gzip
from pathlib import Path

import pytest
from conftest import build_snapshot

from liftcoach_server import schema
from liftcoach_server.errors import UnreadableSnapshot
from liftcoach_server.inspection import inspect


def test_it_reads_the_version_out_of_the_file(tmp_path: Path) -> None:
    archive = build_snapshot(tmp_path / "snapshot.sqlite.gz")
    assert inspect(archive).schema.version == schema.KNOWN_MIGRATIONS[-1]


def test_it_counts_the_rows_it_finds(tmp_path: Path) -> None:
    archive = build_snapshot(tmp_path / "snapshot.sqlite.gz", workouts=840)
    counts = inspect(archive).row_counts

    assert counts["workout"] == 840
    assert counts["exercise"] == 0


def test_grdb_tables_are_not_counted_as_user_data(tmp_path: Path) -> None:
    """The same exclusion `SnapshotExporter.describe` applies on the way out.
    If the two ever disagreed, comparing the phone's counts against the
    server's would report a difference that isn't one."""
    archive = build_snapshot(tmp_path / "snapshot.sqlite.gz")
    assert not [name for name in inspect(archive).row_counts if name.startswith("grdb_")]


def test_a_snapshot_from_a_newer_build_is_read_and_marked(tmp_path: Path) -> None:
    archive = build_snapshot(
        tmp_path / "snapshot.sqlite.gz",
        migrations=schema.KNOWN_MIGRATIONS + ("v15_futureThing",),
    )
    contents = inspect(archive)

    assert contents.schema.newer_than_server
    assert contents.schema.unrecognized == ("v15_futureThing",)
    # Still read. A newer file is storable and countable; what it isn't is
    # something 2.3 should answer questions about.
    assert contents.row_counts["workout"] == 3


def test_a_file_that_is_not_gzip_is_unreadable(tmp_path: Path) -> None:
    archive = tmp_path / "snapshot.sqlite.gz"
    archive.write_bytes(b"this is not a gzip member")

    with pytest.raises(UnreadableSnapshot):
        inspect(archive)


def test_a_truncated_upload_is_unreadable(tmp_path: Path) -> None:
    """The realistic failure: the phone lost the connection partway through a
    PUT that S3 nonetheless completed as a shorter object."""
    archive = build_snapshot(tmp_path / "snapshot.sqlite.gz")
    whole = archive.read_bytes()
    archive.write_bytes(whole[: len(whole) // 2])

    with pytest.raises(UnreadableSnapshot):
        inspect(archive)


def test_gzip_of_something_that_is_not_a_database_is_unreadable(tmp_path: Path) -> None:
    archive = tmp_path / "snapshot.sqlite.gz"
    with gzip.open(archive, "wb") as sink:
        sink.write(b"perfectly valid gzip, not a database")

    with pytest.raises(UnreadableSnapshot):
        inspect(archive)


def test_somebody_elses_sqlite_database_is_unreadable(tmp_path: Path) -> None:
    """A real SQLite file with no `grdb_migrations`. It opens, it queries, and
    it still isn't ours — which is a different failure from a corrupt file and
    lands in the same place on purpose."""
    import sqlite3

    raw = tmp_path / "other.sqlite"
    connection = sqlite3.connect(raw)
    with connection:
        connection.execute("CREATE TABLE notes (body TEXT)")
    connection.close()

    archive = tmp_path / "snapshot.sqlite.gz"
    with gzip.open(archive, "wb") as sink:
        sink.write(raw.read_bytes())

    with pytest.raises(UnreadableSnapshot):
        inspect(archive)


def test_it_never_writes_to_the_file_it_reads(tmp_path: Path) -> None:
    """Read-only isn't hygiene here. A writable open invites something to
    migrate a snapshot on the way past and report a version it was never
    written at — the failure `SnapshotExporter` guards against on the device by
    opening its own export read-only."""
    archive = build_snapshot(tmp_path / "snapshot.sqlite.gz")
    before = archive.read_bytes()

    inspect(archive)

    assert archive.read_bytes() == before
    assert sorted(p.name for p in tmp_path.iterdir()) == ["snapshot.sqlite.gz"]

"""The indexer, end to end against a real file in a fake bucket."""

from __future__ import annotations

import gzip
from pathlib import Path

import pytest
from conftest import FakeObjects, build_snapshot, event_for

from liftcoach_server import handlers, schema
from liftcoach_server.errors import MalformedKey
from liftcoach_server.snapshots import object_key


def stored(objects: FakeObjects, tmp_path: Path, subject: str = "sub-abc", **kwargs) -> None:
    """Puts a real snapshot in the fake bucket under `subject`'s prefix."""
    archive = build_snapshot(tmp_path / "snapshot.sqlite.gz", **kwargs)
    objects.put(object_key(subject), archive.read_bytes(), metadata={"device-id": "phone-1"})


def test_it_records_what_the_file_says(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    stored(objects, tmp_path, workouts=840)

    assert handlers.index_snapshot(event_for()) == {"indexed": 1, "unreadable": 0}

    meta = deps.meta.read("sub-abc")
    assert meta is not None
    assert meta.schema_version == schema.KNOWN_MIGRATIONS[-1]
    assert meta.row_counts["workout"] == 840
    assert meta.readable


def test_the_recorded_version_comes_from_the_file_not_the_metadata(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    """**The claim the whole redesign rests on.** The phone writes its own
    metadata with its own credentials and no signature covers it, so the object
    says one thing and the file says another. The index must follow the file.
    """
    archive = build_snapshot(tmp_path / "snapshot.sqlite.gz")
    objects.put(
        object_key("sub-abc"),
        archive.read_bytes(),
        metadata={"schema-version": "v1_core", "row-counts": '{"workout": 99999}'},
    )

    handlers.index_snapshot(event_for())

    meta = deps.meta.read("sub-abc")
    assert meta is not None
    assert meta.schema_version == schema.KNOWN_MIGRATIONS[-1]
    assert meta.row_counts["workout"] == 3


def test_it_reads_the_version_the_event_named(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    """Two uploads a minute apart — a finished workout and a plan save — put
    two versions in the bucket. The event for the first must not read the
    second, or the record carries one object's contents under another's etag.
    """
    first = build_snapshot(tmp_path / "first.sqlite.gz", workouts=10)
    second = build_snapshot(tmp_path / "second.sqlite.gz", workouts=20)
    key = object_key("sub-abc")
    objects.put(key, first.read_bytes(), version_id="v1")
    objects.put(key, second.read_bytes(), version_id="v2")

    handlers.index_snapshot(event_for(version_id="v1"))

    meta = deps.meta.read("sub-abc")
    assert meta is not None
    assert meta.row_counts["workout"] == 10
    assert meta.version_id == "v1"
    assert objects.downloads == [(key, "v1")]


def test_an_unreadable_file_is_recorded_rather_than_retried(
    deps: handlers.Deps, objects: FakeObjects
) -> None:
    objects.put(object_key("sub-abc"), b"not a gzip at all")

    assert handlers.index_snapshot(event_for()) == {"indexed": 0, "unreadable": 1}

    meta = deps.meta.read("sub-abc")
    assert meta is not None
    assert not meta.readable
    assert meta.problem
    # Still a record. An empty index is indistinguishable from an upload that
    # never happened, which is the state that reads as "nothing is wrong."
    assert meta.etag == "abc123"
    assert meta.uploaded_at == "2026-08-21T10:00:00.000Z"


def test_a_newer_schema_is_recorded_with_its_marker(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    stored(objects, tmp_path, migrations=schema.KNOWN_MIGRATIONS + ("v15_futureThing",))

    handlers.index_snapshot(event_for())

    meta = deps.meta.read("sub-abc")
    assert meta is not None
    assert meta.newer_than_server
    assert meta.unrecognized_migrations == ("v15_futureThing",)


def test_the_subject_comes_from_the_prefix(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    stored(objects, tmp_path, subject="sub-xyz")

    handlers.index_snapshot(event_for(subject="sub-xyz"))

    assert deps.meta.read("sub-xyz") is not None
    assert deps.meta.read("sub-abc") is None


def test_something_else_in_the_bucket_is_ignored(
    deps: handlers.Deps, objects: FakeObjects
) -> None:
    result = handlers.index_snapshot(event_for(key="users/sub-abc/notes.txt"))

    assert result == {"indexed": 0, "unreadable": 0}
    assert deps.meta.read("sub-abc") is None


def test_a_key_outside_the_user_prefix_is_refused(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    """Unreachable through the event filter, and it raises rather than being
    quietly skipped: a snapshot at an unexpected path means the bucket layout
    or the IAM policy has changed under this code, which is worth a failed
    invocation and an alarm."""
    archive = build_snapshot(tmp_path / "snapshot.sqlite.gz")
    objects.put("stray/snapshot.sqlite.gz", archive.read_bytes())

    with pytest.raises(MalformedKey):
        handlers.index_snapshot(event_for(key="stray/snapshot.sqlite.gz"))


def test_indexing_is_idempotent(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    """S3 can redeliver a record. Same key, same version, same derived content
    — so a duplicate costs a write and nothing else."""
    stored(objects, tmp_path)

    handlers.index_snapshot(event_for())
    first = deps.meta.read("sub-abc")
    handlers.index_snapshot(event_for())
    second = deps.meta.read("sub-abc")

    assert first == second


def test_a_transient_failure_escapes_so_s3_retries(
    deps: handlers.Deps, objects: FakeObjects
) -> None:
    """The other half of the `errors.py` boundary. A file that can't be opened
    is recorded; a bucket that can't be reached is raised, because the retry is
    the thing that fixes it."""

    def unavailable(*args: object, **kwargs: object) -> None:
        raise TimeoutError("S3 is having a moment")

    objects.download = unavailable  # type: ignore[assignment]

    with pytest.raises(TimeoutError):
        handlers.index_snapshot(event_for())

    assert deps.meta.read("sub-abc") is None


def test_a_recovered_upload_replaces_a_recorded_problem(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    """A bad upload followed by a good one must leave the good one. The record
    is derived, so it can be stale but must never be stuck."""
    key = object_key("sub-abc")
    objects.put(key, b"truncated", version_id="v1")
    handlers.index_snapshot(event_for(version_id="v1"))
    assert deps.meta.read("sub-abc").readable is False

    archive = build_snapshot(tmp_path / "snapshot.sqlite.gz")
    objects.put(key, archive.read_bytes(), version_id="v2")
    handlers.index_snapshot(event_for(version_id="v2"))

    meta = deps.meta.read("sub-abc")
    assert meta is not None
    assert meta.readable
    assert meta.problem == ""


def test_the_device_id_is_carried_but_only_as_a_note(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    stored(objects, tmp_path)

    handlers.index_snapshot(event_for())

    assert deps.meta.read("sub-abc").device_id == "phone-1"


def test_gzip_that_expands_absurdly_is_refused(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    """A gzip bomb is a small object that fills `/tmp`. This is a bound, not a
    quota — a real five-year snapshot is ~10 MB uncompressed."""
    from liftcoach_server import inspection

    archive = tmp_path / "bomb.gz"
    with gzip.open(archive, "wb") as sink:
        sink.write(b"\0" * (inspection.MAX_UNCOMPRESSED_BYTES + 1))
    objects.put(object_key("sub-abc"), archive.read_bytes())

    assert handlers.index_snapshot(event_for()) == {"indexed": 0, "unreadable": 1}
    assert deps.meta.read("sub-abc").readable is False


def test_a_late_invocation_does_not_overwrite_a_newer_record(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    """Two uploads, two invocations, and no ordering between them.

    Reserved concurrency is 2 on the deployed function, so this is reachable
    rather than theoretical: finishing a workout and backgrounding the app
    seconds later produce two events, and nothing makes the first one's
    invocation finish first. The index has to end up describing the newest
    *upload*, not the last invocation to run.
    """
    for version in ("v1", "v2"):
        archive = build_snapshot(tmp_path / f"{version}.sqlite.gz")
        objects.put(
            object_key("sub-abc"), archive.read_bytes(), version_id=version, metadata={}
        )

    # The newer upload is indexed first — the race this guards against.
    handlers.index_snapshot(
        event_for(version_id="v2", etag='"bbb"', event_time="2026-08-21T10:00:30.000Z")
    )
    handlers.index_snapshot(
        event_for(version_id="v1", etag='"aaa"', event_time="2026-08-21T10:00:00.000Z")
    )

    record = deps.meta.read("sub-abc")
    assert record.version_id == "v2"
    assert record.etag == "bbb"


def test_two_events_at_the_same_instant_still_write(
    deps: handlers.Deps, objects: FakeObjects, tmp_path: Path
) -> None:
    """A tie writes rather than being refused — see `MetaStore`."""
    for version in ("v1", "v2"):
        archive = build_snapshot(tmp_path / f"{version}.sqlite.gz")
        objects.put(
            object_key("sub-abc"), archive.read_bytes(), version_id=version, metadata={}
        )

    at = "2026-08-21T10:00:00.000Z"
    handlers.index_snapshot(event_for(version_id="v1", etag='"aaa"', event_time=at))
    handlers.index_snapshot(event_for(version_id="v2", etag='"bbb"', event_time=at))

    assert deps.meta.read("sub-abc").version_id == "v2"

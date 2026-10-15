"""The coach reading the log: right answers, read-only, bounded, honest about
staleness and about schemas it doesn't know (INFRA-SPEC §14).

Against a database built from the app's real schema (`fixtures/schema.sql`,
dumped from a fresh install), so a renamed column fails here rather than in
front of the lifter.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

import pytest
from conftest import REPO_ROOT  # noqa: F401 - keeps conftest's path setup

from liftcoach_server import coach, handlers, log_tools, schema
from liftcoach_server.accounts import AccountUser, InvalidToken
from liftcoach_server.coach import InMemoryReplyStore, ModelAnswer
from liftcoach_server.log_source import LocalSnapshotSource, describe

FIXTURE = Path(__file__).parent / "fixtures" / "schema.sql"
USER = "u-1"


def build(path: Path, extra_migration: str | None = None) -> Path:
    """A snapshot with a little real-looking training in it."""
    db = sqlite3.connect(path)
    db.executescript(FIXTURE.read_text())
    if extra_migration:
        db.execute("INSERT INTO grdb_migrations VALUES (?)", (extra_migration,))
    db.executescript(f"""
        INSERT INTO user (id, name, email, preferredUnit) VALUES ('{USER}', 'Rob', '', 'lb');
        INSERT INTO exercise (id, name, muscleGroup) VALUES (1, 'Barbell Squat', 'quadriceps'),
                                                            (2, 'Barbell Bench Press', 'chest'),
                                                            (3, 'Running, Treadmill', 'quadriceps');
        INSERT INTO workout (id, startTime, endTime, notes, usernotes) VALUES
          ('w1', '2026-10-06 01:00:00.000', '2026-10-06 02:15:00.000', 'Week 1 Mon - Squat', NULL),
          ('w2', '2026-10-08 01:00:00.000', '2026-10-08 02:00:00.000', 'Week 1 Wed - Bench', 'Shoulder felt off'),
          ('w3', '2026-10-13 01:00:00.000', '2026-10-13 02:20:00.000', 'Week 2 Mon - Squat', NULL),
          ('w4', '2026-10-14 01:00:00.000', NULL, 'In progress', NULL);
        INSERT INTO workoutExercise (id, workoutId, exerciseId, groupIndex, position, usernotes) VALUES
          ('e1', 'w1', 1, 0, 0, NULL), ('e2', 'w2', 2, 0, 0, 'Paused reps'),
          ('e3', 'w3', 1, 0, 0, NULL), ('e4', 'w3', 3, 1, 0, NULL), ('e5', 'w4', 1, 0, 0, NULL);
        INSERT INTO workoutSet (id, workoutExerciseId, position, reps, weightValue, weightUnit, complete, setType, rpe,
                                durationSeconds, distanceValue, distanceUnit) VALUES
          ('s1', 'e1', 0, 5, 135, 'lb', 1, 'warmup', NULL, NULL, NULL, NULL),
          ('s2', 'e1', 1, 3, 365, 'lb', 1, 'working', 8, NULL, NULL, NULL),
          ('s3', 'e2', 0, 5, 245, 'lb', 1, 'working', 7.5, NULL, NULL, NULL),
          ('s4', 'e3', 0, 3, 375, 'lb', 1, 'working', 9, NULL, NULL, NULL),
          ('s5', 'e3', 1, 3, 375, 'lb', 0, 'working', NULL, NULL, NULL, NULL),
          ('s6', 'e4', 0, NULL, NULL, NULL, 1, 'working', NULL, 1800, 3.1, 'mi'),
          ('s7', 'e5', 0, 1, 500, 'lb', 1, 'working', 10, NULL, NULL, NULL);
        INSERT INTO achievedMax (userId, exerciseId, value, unit, date, notes) VALUES
          ('{USER}', 1, 365, 'lb', '2026-10-06 01:30:00.000', '3 reps'),
          ('{USER}', 1, 375, 'lb', '2026-10-13 01:30:00.000', '3 reps');
        INSERT INTO goalMax (userId, exerciseId, value, unit) VALUES ('{USER}', 1, 495, 'lb'), ('{USER}', 2, 365, 'lb');
        INSERT INTO bodyWeight (userId, day, value, unit) VALUES ('{USER}', '2026-10-12 07:00:00.000', 198.4, 'lb');
        INSERT INTO block (id, userId, startDate, endDate, notes) VALUES
          ('b1', '{USER}', '2026-10-05 07:00:00.000', '2026-12-28 07:00:00.000', 'Block 1 — Strength');
        INSERT INTO plannedWorkout (id, blockId, date) VALUES ('p1', 'b1', '2026-10-06 07:00:00.000'),
                                                             ('p2', 'b1', '2026-10-07 07:00:00.000');
    """)
    db.commit()
    db.close()
    return path


def reader(tmp_path: Path, zone: str | None = "America/Los_Angeles", **kwargs: Any) -> log_tools.LogReader:
    snapshot = describe(build(tmp_path / "snap.sqlite", **kwargs), "2026-10-15 05:19:56.000")
    return log_tools.LogReader(snapshot, zone)


def ask(r: log_tools.LogReader, name: str, **args: Any) -> str:
    text, error = r.run(name, args)
    assert not error, text
    return text


def test_the_fixture_is_the_schema_this_server_knows() -> None:
    """Regenerate `fixtures/schema.sql` when a migration lands (its header
    says how). Without this, the queries are tested against last month's
    tables."""
    applied = [line.split("'")[1] for line in FIXTURE.read_text().splitlines()
               if line.startswith("INSERT INTO grdb_migrations")]
    assert tuple(applied) == schema.KNOWN_MIGRATIONS


def test_every_answer_says_how_current_the_log_is(tmp_path: Path) -> None:
    # 05:19 UTC is 22:19 the previous evening in Los Angeles.
    assert ask(reader(tmp_path), "maxes").startswith("Log as of Wed 2026-10-14 22:19.")


def test_the_overview_counts_finished_workouts_and_names_the_lifts(tmp_path: Path) -> None:
    text = ask(reader(tmp_path), "training_overview")
    assert "3 finished workouts" in text  # the in-progress one isn't history
    assert "- 1 — Barbell Squat: 2 sessions" in text
    assert "heaviest 375 lb × 3" in text  # completed working sets only: not the unfinished 500
    assert "Current block: Block 1 — Strength" in text
    assert "1 trained" in text


def test_exercise_history_is_session_by_session_most_recent_first(tmp_path: Path) -> None:
    text = ask(reader(tmp_path), "exercise_history", exercise_id=1)
    lines = text.splitlines()
    assert lines[2] == "Barbell Squat — last 2 sessions:"
    assert lines[3] == "Mon 2026-10-12: 375lb×3 @9"  # local date, completed sets only
    assert lines[4] == "Mon 2026-10-05: W 135lb×5, 365lb×3 @8"


def test_an_unknown_exercise_says_how_to_find_one(tmp_path: Path) -> None:
    assert "list_logged_exercises" in ask(reader(tmp_path), "exercise_history", exercise_id=999)


def test_recent_workouts_carry_notes_duration_and_cardio(tmp_path: Path) -> None:
    text = ask(reader(tmp_path), "recent_workouts", count=2)
    assert "Week 2 Mon - Squat (80 min)" in text
    assert "Running, Treadmill: 30:00 · 3.1 mi" in text
    assert "Lifter's note: Shoulder felt off" in text
    assert "Note: Paused reps" in text


def test_maxes_keep_achieved_and_goal_apart(tmp_path: Path) -> None:
    text = ask(reader(tmp_path), "maxes")
    assert "- 1 — Barbell Squat: 375 lb (Mon 2026-10-12, 3 reps) | goal 495 lb" in text
    assert "- 2 — Barbell Bench Press: none recorded | goal 365 lb" in text


def test_bodyweight_and_the_exercise_list(tmp_path: Path) -> None:
    r = reader(tmp_path)
    assert "198.4 lb" in ask(r, "bodyweight")
    assert "- 3 — Running, Treadmill: 1" in ask(r, "list_logged_exercises")


def test_the_log_is_opened_read_only(tmp_path: Path) -> None:
    """Core Tenets §8 by construction: the connection can't write."""
    r = reader(tmp_path)
    ask(r, "maxes")
    with pytest.raises(sqlite3.OperationalError):
        r._db.execute("DELETE FROM workout")


def test_a_log_from_a_newer_app_is_declined_not_guessed_at(tmp_path: Path) -> None:
    text, error = reader(tmp_path, extra_migration="v99_future").run("maxes", {})
    assert not error
    assert "newer version of the app" in text and "v99_future" in text


def test_no_backup_yet_says_so(tmp_path: Path) -> None:
    text, error = log_tools.LogReader(None).run("training_overview", {})
    assert not error and "hasn't backed up" in text


def test_long_answers_are_cut_and_say_so(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(log_tools, "OUTPUT_LIMIT", 120)
    text = ask(reader(tmp_path), "training_overview")
    assert len(text) < 260 and "cut off" in text


def test_a_bad_time_zone_falls_back_to_utc(tmp_path: Path) -> None:
    assert ask(reader(tmp_path, zone="Mars/Olympus"), "maxes").startswith("Log as of Thu 2026-10-15 05:19.")


# ── Through the coach ────────────────────────────────────────────────────────


class Accounts:
    def user(self, token: str) -> AccountUser:
        if token != "token":
            raise InvalidToken("bad")
        return AccountUser(subject="sub-a", username="x")


class Scripted:
    def __init__(self, calls: list[tuple[str, dict[str, Any]]]) -> None:
        self.calls = calls
        self.results: list[tuple[str, bool]] = []
        self.tool_names: list[str] = []

    def answer(self, system: str, context: str, messages: Any, toolbox: coach.Toolbox) -> ModelAnswer:
        self.tool_names = [t["name"] for t in toolbox.tools]
        self.results = [toolbox.run(name, args) for name, args in self.calls]
        return ModelAnswer(text="ok")


@pytest.fixture
def snapshot_path(tmp_path: Path) -> Path:
    return build(tmp_path / "snap.sqlite")


def coach_with(model: Scripted, source: LocalSnapshotSource | None) -> None:
    handlers.configure_coach(handlers.CoachDeps(
        accounts=Accounts(), store=InMemoryReplyStore(), model=model, snapshots=source))


def send(message: str = "8f2c1d9e-4b6a-4c3e-9f1a-2d7b5e6c8a90") -> dict[str, Any]:
    return handlers.coach_reply({"accessToken": "token", "messageId": message, "text": "How's my squat?",
                                 "timeZone": "America/Los_Angeles"})


def test_the_coach_is_offered_the_log_tools_and_reads_through_them(snapshot_path: Path) -> None:
    model = Scripted([("maxes", {}), ("exercise_history", {"exercise_id": 1})])
    source = LocalSnapshotSource(snapshot_path)
    coach_with(model, source)
    try:
        send()
    finally:
        handlers.configure_coach(None)
    assert {"training_overview", "remember"} <= set(model.tool_names)
    assert "375 lb" in model.results[0][0]
    # Fetched once for the turn, however many log tools were called.
    assert source.fetches == 1


def test_a_turn_that_never_reads_the_log_never_fetches_it(snapshot_path: Path) -> None:
    source = LocalSnapshotSource(snapshot_path)
    coach_with(Scripted([("remember", {"category": "goals", "text": "Squat 500."})]), source)
    try:
        send()
    finally:
        handlers.configure_coach(None)
    assert source.fetches == 0


def test_without_a_snapshot_source_the_log_tools_are_simply_not_offered() -> None:
    model = Scripted([])
    coach_with(model, None)
    try:
        send()
    finally:
        handlers.configure_coach(None)
    assert "training_overview" not in model.tool_names
    assert "remember" in model.tool_names


# ── The S3 source ────────────────────────────────────────────────────────────


class FakeS3:
    """A bucket with one gzipped snapshot whose etag a test can change."""

    def __init__(self, archive: bytes | None) -> None:
        import datetime

        self.archive = archive
        self.etag = "e1"
        self.gets: list[str] = []
        self.modified = datetime.datetime(2026, 10, 15, 5, 19, 56, tzinfo=datetime.UTC)

    def head_object(self, Bucket: str, Key: str) -> dict[str, Any]:  # noqa: N803
        from botocore.exceptions import ClientError

        if self.archive is None:
            raise ClientError({"Error": {"Code": "404"}}, "HeadObject")
        return {"ETag": f'"{self.etag}"', "LastModified": self.modified}

    def get_object(self, Bucket: str, Key: str, IfMatch: str) -> dict[str, Any]:  # noqa: N803
        import io

        assert Key == "users/sub-a/snapshot.sqlite.gz" and IfMatch == f'"{self.etag}"'
        self.gets.append(self.etag)
        return {"Body": io.BytesIO(self.archive)}


def gzipped(path: Path) -> bytes:
    import gzip

    return gzip.compress(path.read_bytes())


def test_s3_source_caches_by_etag_and_refetches_a_new_upload(tmp_path: Path) -> None:
    from liftcoach_server.log_source import S3SnapshotSource

    s3 = FakeS3(gzipped(build(tmp_path / "snap.sqlite")))
    source = S3SnapshotSource("bucket", cache=tmp_path / "cache", client=s3)

    first = source.fetch("sub-a")
    assert first is not None and first.readable and first.uploaded_at == "2026-10-15 05:19:56.000"
    source.fetch("sub-a")
    assert s3.gets == ["e1"]  # cached

    s3.etag = "e2"
    second = source.fetch("sub-a")
    assert s3.gets == ["e1", "e2"]
    assert list((tmp_path / "cache").glob("sub-a-*.sqlite")) == [Path(second.path)]  # old copy gone


def test_s3_source_with_no_upload_is_none(tmp_path: Path) -> None:
    from liftcoach_server.log_source import S3SnapshotSource

    assert S3SnapshotSource("bucket", cache=tmp_path, client=FakeS3(None)).fetch("sub-a") is None

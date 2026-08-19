"""The strict loader: what it writes, what it refuses, and what it replaces."""

import json
import sqlite3
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from liftimport import device
from liftimport.load import LoadError, load
from liftimport.mapping import Mapping, MappingError
from liftimport.staging import Staging, StagedExercise, StagedSet, StagedWorkout


def _entries(raw):
    path = Path("/tmp/_liftimport_map_test.json")
    path.write_text(json.dumps({"source": "test", "entries": raw}), encoding="utf-8")
    return Mapping.read(path).entries


def make_mapping(raw):
    return Mapping(source="strong-csv", entries=_entries(raw))


SQUAT = {"name": "Squat (Barbell)", "slug": "Barbell_Squat"}


def make_staging(exercises=None, **kwargs):
    exercises = exercises if exercises is not None else [
        StagedExercise(
            source_name="Squat (Barbell)",
            sets=[
                StagedSet(reps=5, weight=225.0, weight_unit="lb", rpe=8.0),
                StagedSet(reps=5, weight=245.0, weight_unit="lb"),
            ],
        )
    ]
    workout = StagedWorkout(
        start=kwargs.get("start", datetime(2024, 1, 5, 17, 30, tzinfo=ZoneInfo("America/Los_Angeles"))),
        end=kwargs.get("end", datetime(2024, 1, 5, 18, 35, tzinfo=ZoneInfo("America/Los_Angeles"))),
        title=kwargs.get("title", "Legs"),
        notes=kwargs.get("notes"),
        exercises=exercises,
    )
    return Staging(
        source="strong-csv",
        timezone_name="America/Los_Angeles",
        workouts=[workout],
    )


def rows(database, sql, args=()):
    connection = sqlite3.connect(database)
    try:
        return connection.execute(sql, args).fetchall()
    finally:
        connection.close()


# -- writing ---------------------------------------------------------------


def test_a_workout_lands_with_its_sets(app_database):
    result = load(make_staging(), make_mapping([SQUAT]), app_database)
    assert (result.workouts, result.exercises, result.sets) == (1, 1, 2)

    (workout,) = rows(app_database, "SELECT startTime, endTime, notes, source, blockId FROM workout")
    assert workout[0] == "2024-01-06 01:30:00.000"
    assert workout[1] == "2024-01-06 02:35:00.000"
    assert workout[2] == "Legs"
    assert workout[3] == "strong-csv"
    # Imported history belongs to no block, and that has to stay true: block
    # adherence is computed by joining on blockId.
    assert workout[4] is None

    logged = rows(
        app_database,
        "SELECT reps, weightValue, weightUnit, complete, setType, rpe FROM workoutSet ORDER BY position",
    )
    assert logged == [(5, 225.0, "lb", 1, "working", 8.0), (5, 245.0, "lb", 1, "working", None)]


def test_day_is_the_local_start_of_day_stored_as_utc(app_database):
    """The trap: 17:30 Pacific is the 6th in UTC but the 5th on the calendar.

    `workout.day` is what every "was this today" lookup compares against, so it
    must be midnight *local*, expressed in UTC — 08:00Z at UTC-8.
    """
    load(make_staging(), make_mapping([SQUAT]), app_database)
    (day,) = rows(app_database, "SELECT day FROM workout")[0]
    assert day == "2024-01-05 08:00:00.000"


def test_timed_work_round_trips(app_database):
    staging = make_staging([
        StagedExercise(
            source_name="Squat (Barbell)",
            sets=[StagedSet(duration_seconds=720.0, distance=2.4, distance_unit="mi")],
        )
    ])
    load(staging, make_mapping([SQUAT]), app_database)
    assert rows(
        app_database,
        "SELECT reps, weightValue, durationSeconds, distanceValue, distanceUnit FROM workoutSet",
    ) == [(None, None, 720.0, 2.4, "mi")]


def test_the_sources_own_wording_becomes_a_variant(app_database):
    entry = {"name": "Squat (Barbell)", "slug": "Barbell_Squat", "variant": "Paused squat"}
    load(make_staging(), make_mapping([entry]), app_database)
    assert rows(app_database, "SELECT variant FROM workoutExercise") == [("Paused squat",)]


def test_every_exercise_is_its_own_group(app_database):
    """Strong records no supersets, so claiming one would be an invention."""
    staging = make_staging([
        StagedExercise(source_name="Squat (Barbell)", sets=[StagedSet(reps=5)]),
        StagedExercise(source_name="Squat (Barbell)", sets=[StagedSet(reps=5)]),
    ])
    load(staging, make_mapping([SQUAT]), app_database)
    assert rows(
        app_database, "SELECT groupIndex, position FROM workoutExercise ORDER BY groupIndex"
    ) == [(0, 0), (1, 0)]


# -- resolving exercises ---------------------------------------------------


def test_a_created_exercise_is_minted_once_and_reused(app_database):
    entry = {
        "name": "Belt Squat",
        "create": {"name": "Belt Squat", "muscleGroup": "Quadriceps", "equipment": "machine"},
    }
    staging = make_staging([StagedExercise(source_name="Belt Squat", sets=[StagedSet(reps=5)])])

    first = load(staging, make_mapping([entry]), app_database)
    assert first.created_exercises == 1
    second = load(staging, make_mapping([entry]), app_database)
    assert second.created_exercises == 0
    assert rows(app_database, "SELECT COUNT(*) FROM exercise WHERE name = 'Belt Squat'") == [(1,)]


def test_an_open_choice_is_created_with_its_flag_and_suggestions(app_database):
    entry = {
        "name": "Triceps Extension",
        "openChoice": {
            "name": "Triceps extension",
            "muscleGroup": "Triceps",
            "suggestions": ["Pushdown"],
        },
    }
    staging = make_staging([
        StagedExercise(source_name="Triceps Extension", sets=[StagedSet(reps=10, weight=90.0, weight_unit="lb")])
    ])
    load(staging, make_mapping([entry]), app_database)
    assert rows(
        app_database,
        "SELECT isOpenChoice, suggestions FROM exercise WHERE name = 'Triceps extension'",
    ) == [(1, '["Pushdown"]')]


def test_a_slug_missing_from_the_catalog_aborts(app_database):
    entry = {"name": "Squat (Barbell)", "slug": "Not_In_The_Catalog"}
    with pytest.raises(MappingError, match="isn't in this database's catalog"):
        load(make_staging(), make_mapping([entry]), app_database)
    assert rows(app_database, "SELECT COUNT(*) FROM workout") == [(0,)]


def test_an_unmapped_name_aborts_before_anything_is_written():
    """The ProgramLoader rule: half an import reads exactly like a whole one."""
    mapping = make_mapping([SQUAT])
    with pytest.raises(MappingError, match="no mapping"):
        mapping.require(["Squat (Barbell)", "Nordic Leg Curl"])


# -- re-running ------------------------------------------------------------


def test_reloading_replaces_rather_than_doubles(app_database):
    load(make_staging(), make_mapping([SQUAT]), app_database)
    second = load(make_staging(), make_mapping([SQUAT]), app_database)

    assert second.replaced == 1
    assert rows(app_database, "SELECT COUNT(*) FROM workout") == [(1,)]
    assert rows(app_database, "SELECT COUNT(*) FROM workoutSet") == [(2,)]
    assert rows(app_database, "SELECT COUNT(*) FROM achievedMax") == [(2,)]


def test_a_workout_logged_in_the_app_survives_a_reload(app_database):
    """Only what this source wrote is replaceable. Everything else is history."""
    connection = sqlite3.connect(app_database)
    connection.execute(
        "INSERT INTO workout (id, day, startTime, endTime) VALUES ('LOCAL', ?, ?, ?)",
        ("2024-02-01 08:00:00.000", "2024-02-01 17:00:00.000", "2024-02-01 18:00:00.000"),
    )
    connection.commit()
    connection.close()

    load(make_staging(), make_mapping([SQUAT]), app_database)
    load(make_staging(), make_mapping([SQUAT]), app_database)
    assert rows(app_database, "SELECT COUNT(*) FROM workout WHERE source IS NULL") == [(1,)]


# -- achieved maxes --------------------------------------------------------


def test_maxes_are_written_tagged_with_their_source(app_database):
    load(make_staging(), make_mapping([SQUAT]), app_database)
    assert rows(
        app_database, "SELECT value, unit, notes, source FROM achievedMax ORDER BY value"
    ) == [(225.0, "lb", "5 reps", "strong-csv"), (245.0, "lb", "5 reps", "strong-csv")]


def test_maxes_can_be_skipped(app_database):
    result = load(make_staging(), make_mapping([SQUAT]), app_database, replay_maxes=False)
    assert result.max_events == 0
    assert rows(app_database, "SELECT COUNT(*) FROM achievedMax") == [(0,)]


# -- refusing a database it shouldn't touch --------------------------------


def test_a_database_without_v13_is_refused(tmp_path):
    path = tmp_path / "old.sqlite"
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        CREATE TABLE user (id TEXT PRIMARY KEY, name TEXT, email TEXT);
        CREATE TABLE exercise (id INTEGER PRIMARY KEY, name TEXT, muscleGroup TEXT, sourceSlug TEXT, isOpenChoice BOOLEAN);
        CREATE TABLE achievedMax (rowid_ INTEGER PRIMARY KEY, userId TEXT, exerciseId INTEGER, value DOUBLE, unit TEXT, date DATETIME, notes TEXT);
        CREATE TABLE workout (id TEXT PRIMARY KEY, day DATETIME);
        CREATE TABLE workoutExercise (id TEXT PRIMARY KEY);
        CREATE TABLE workoutSet (id TEXT PRIMARY KEY, reps INTEGER);
        """
    )
    connection.commit()
    connection.close()

    with pytest.raises(LoadError, match="v13_setDurationDistance"):
        load(make_staging(), make_mapping([SQUAT]), path)


def test_a_database_with_no_user_is_refused(tmp_path, app_database):
    connection = sqlite3.connect(app_database)
    connection.execute("DELETE FROM user")
    connection.commit()
    connection.close()

    with pytest.raises(LoadError, match="no user row"):
        load(make_staging(), make_mapping([SQUAT]), app_database)


def test_checkpoint_empties_the_write_ahead_log(tmp_path, app_database):
    """The database the app owns is in WAL mode, so `db.sqlite` alone is not the
    database. A copy taken without folding the log in is missing whatever is
    still in it — and a rewritten main file pushed back beside the *old* log
    lets SQLite replay stale frames over new content."""
    connection = sqlite3.connect(app_database)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("INSERT INTO workout (id, startTime) VALUES ('X', '2026-01-01 00:00:00.000')")
    connection.commit()
    connection.close()

    wal = Path(str(app_database) + "-wal")
    if wal.exists() and wal.stat().st_size == 0:
        # Python checkpointed on close; write again with the connection held
        # open so there is a log to truncate.
        held = sqlite3.connect(app_database)
        held.execute("INSERT INTO workout (id, startTime) VALUES ('Y', '2026-01-02 00:00:00.000')")
        held.commit()
        assert wal.stat().st_size > 0
        held.close()

    device.checkpoint(app_database)

    assert not wal.exists() or wal.stat().st_size == 0
    # And nothing was lost folding it in.
    connection = sqlite3.connect(app_database)
    assert connection.execute("SELECT COUNT(*) FROM workout").fetchone()[0] >= 1
    connection.close()

import sqlite3
import textwrap
from pathlib import Path

import pytest

#: A minimal stand-in for the app's schema — only the tables and columns the
#: loader touches. Deliberately hand-written rather than derived from GRDB: if
#: it drifts from the real migrations, `_require_schema` and the foreign keys
#: are what catch it, and those are exactly what these tests exercise.
SCHEMA = textwrap.dedent(
    """
    CREATE TABLE user (id TEXT PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL);
    CREATE TABLE exercise (
        id INTEGER PRIMARY KEY, name TEXT NOT NULL, muscleGroup TEXT NOT NULL,
        equipment TEXT, primaryMuscles TEXT, secondaryMuscles TEXT,
        instructions TEXT, level TEXT, category TEXT, mechanic TEXT, force TEXT,
        sourceSlug TEXT, isOpenChoice BOOLEAN NOT NULL DEFAULT 0, suggestions TEXT
    );
    CREATE TABLE achievedMax (
        rowid_ INTEGER PRIMARY KEY AUTOINCREMENT,
        userId TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
        exerciseId INTEGER NOT NULL REFERENCES exercise(id) ON DELETE CASCADE,
        value DOUBLE NOT NULL, unit TEXT NOT NULL, date DATETIME NOT NULL,
        notes TEXT, source TEXT
    );
    CREATE TABLE workout (
        id TEXT PRIMARY KEY, blockId TEXT, day DATETIME, startTime DATETIME,
        endTime DATETIME, notes TEXT, usernotes TEXT, source TEXT
    );
    CREATE TABLE workoutExercise (
        id TEXT PRIMARY KEY,
        workoutId TEXT NOT NULL REFERENCES workout(id) ON DELETE CASCADE,
        exerciseId INTEGER NOT NULL REFERENCES exercise(id),
        groupIndex INTEGER NOT NULL, position INTEGER NOT NULL,
        variant TEXT, notes TEXT, usernotes TEXT
    );
    CREATE TABLE workoutSet (
        id TEXT PRIMARY KEY,
        workoutExerciseId TEXT NOT NULL REFERENCES workoutExercise(id) ON DELETE CASCADE,
        position INTEGER NOT NULL, reps INTEGER, weightValue DOUBLE,
        weightUnit TEXT, complete BOOLEAN, setType TEXT, timeComplete DATETIME,
        restTime INTEGER, restOverride INTEGER, unit TEXT,
        durationSeconds DOUBLE, distanceValue DOUBLE, distanceUnit TEXT,
        rpe DOUBLE, notes TEXT, usernotes TEXT, plannedFrom TEXT
    );
    """
)


@pytest.fixture
def app_database(tmp_path: Path) -> Path:
    path = tmp_path / "db.sqlite"
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA)
    connection.execute(
        "INSERT INTO user (id, name, email) VALUES ('U1', 'Test', 't@example.com')"
    )
    connection.execute(
        """
        INSERT INTO exercise (id, name, muscleGroup, sourceSlug, isOpenChoice)
        VALUES (1000, 'Barbell Squat', 'Quadriceps', 'Barbell_Squat', 0)
        """
    )
    connection.commit()
    connection.close()
    return path

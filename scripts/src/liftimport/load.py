"""Writes staged workouts into an app database.

Strict, transactional, and re-runnable. It makes **no decisions**: every
exercise identity comes from the reviewed mapping, and a name the mapping
doesn't cover has already aborted the run before this module is reached.

Three things about how it writes, each of which has cost time to get wrong
before:

- **It does not create the schema.** The database must already have been
  migrated by launching the app once. Reimplementing GRDB's migrations in
  Python is how two schemas silently diverge, and the failure would land on a
  phone. So this checks for the columns it needs and refuses otherwise.
- **Dates are GRDB's format** — ``YYYY-MM-DD HH:MM:SS.SSS`` in **UTC** — while
  ``workout.day`` is the *local* start of day converted to UTC. Get that second
  one wrong and every workout lands on the neighbouring calendar day, which
  nothing later can detect.
- **Everything happens in one transaction.** A partially imported history reads
  as a real one.

Re-running replaces what this source wrote, matched on ``workout.source`` and
``achievedMax.source``, rather than appending a second copy.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import timezone
from pathlib import Path

from . import maxes
from .mapping import Entry, Mapping, MappingError
from .staging import Staging

#: Where created exercises start numbering. Above the vendored catalog's own
#: range (`CatalogImporter` allocates from 1000) so the two can't collide.
_CREATED_ID_FLOOR = 5000


class LoadError(Exception):
    pass


@dataclass
class Result:
    workouts: int
    exercises: int
    sets: int
    created_exercises: int
    max_events: int
    replaced: int

    def describe(self) -> str:
        lines = [
            f"{self.workouts} workouts, {self.exercises} exercise blocks, "
            f"{self.sets} sets",
            f"{self.created_exercises} catalog entries created",
            f"{self.max_events} achieved-max events",
        ]
        if self.replaced:
            lines.append(f"replaced {self.replaced} previously imported workouts")
        lines.append(
            "exerciseStats will rebuild on the app's next launch "
            "(AppEnvironment.bootstrap)"
        )
        return "\n".join(lines)


def _grdb_date(value) -> str:
    """GRDB's on-disk date format, in UTC."""
    return value.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.") + (
        f"{value.astimezone(timezone.utc).microsecond // 1000:03d}"
    )


def _uuid() -> str:
    """Swift's `UUID.uuidString` is uppercase, and rows are matched on it."""
    return str(uuid.uuid4()).upper()


def _require_schema(connection: sqlite3.Connection) -> None:
    def columns(table: str) -> set[str]:
        return {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}

    missing = []
    for table, needed in (
        ("workoutSet", {"durationSeconds", "distanceValue", "distanceUnit"}),
        ("workout", {"source"}),
        ("achievedMax", {"source"}),
    ):
        found = columns(table)
        if not found:
            raise LoadError(f"{table!r} is missing — is this an app database?")
        missing += [f"{table}.{name}" for name in sorted(needed - found)]

    if missing:
        raise LoadError(
            "database predates migration v13_setDurationDistance "
            f"(missing {', '.join(missing)}). Launch the app once to migrate it."
        )


def _resolve_exercises(
    connection: sqlite3.Connection, mapping: Mapping, names: list[str]
) -> tuple[dict[str, int], dict[int, bool], int]:
    """Maps each source name onto a catalog row id, creating rows where told to.

    Returns the name→id map, whether each id is an open choice (which the max
    replay needs), and how many rows were created.
    """
    resolved: dict[str, int] = {}
    open_choice: dict[int, bool] = {}
    created = 0

    next_id = max(
        _CREATED_ID_FLOOR,
        (connection.execute("SELECT MAX(id) FROM exercise").fetchone()[0] or 0) + 1,
    )

    for name in names:
        entry: Entry = mapping.entries[name]

        if entry.slug:
            row = connection.execute(
                "SELECT id, isOpenChoice FROM exercise WHERE sourceSlug = ?",
                (entry.slug,),
            ).fetchone()
            if row is None:
                # The catalog import hasn't run, or the mapping names a slug
                # this build doesn't ship. Either way the log would be wrong.
                raise MappingError(
                    f"{name!r} maps to slug {entry.slug!r}, which isn't in this "
                    "database's catalog. Launch the app once so CatalogImporter "
                    "runs, or fix the mapping."
                )
            resolved[name] = row[0]
            open_choice[row[0]] = bool(row[1])
            continue

        shape = entry.create or entry.open_choice
        is_open = entry.open_choice is not None
        # Reused by name, so a reload doesn't mint a second copy — the same
        # thing `ProgramLoader.resolveOpenSlots` does for a program's open slots.
        row = connection.execute(
            "SELECT id FROM exercise WHERE name = ? AND isOpenChoice = ?",
            (shape["name"], int(is_open)),
        ).fetchone()
        if row is not None:
            resolved[name] = row[0]
            open_choice[row[0]] = is_open
            continue

        connection.execute(
            """
            INSERT INTO exercise
                (id, name, muscleGroup, equipment, isOpenChoice, suggestions)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                next_id,
                shape["name"],
                shape["muscleGroup"],
                shape.get("equipment"),
                int(is_open),
                json.dumps(shape["suggestions"]) if shape.get("suggestions") else None,
            ),
        )
        resolved[name] = next_id
        open_choice[next_id] = is_open
        next_id += 1
        created += 1

    return resolved, open_choice, created


def load(
    staging: Staging,
    mapping: Mapping,
    database: Path,
    *,
    replay_maxes: bool = True,
) -> Result:
    connection = sqlite3.connect(database)
    connection.execute("PRAGMA foreign_keys = ON")
    try:
        _require_schema(connection)

        user = connection.execute("SELECT id FROM user LIMIT 1").fetchone()
        if user is None:
            raise LoadError(
                "no user row — launch the app once so it creates the local user."
            )
        user_id = user[0]

        with connection:
            replaced = connection.execute(
                "SELECT COUNT(*) FROM workout WHERE source = ?", (staging.source,)
            ).fetchone()[0]
            connection.execute("DELETE FROM workout WHERE source = ?", (staging.source,))
            connection.execute(
                "DELETE FROM achievedMax WHERE source = ? AND userId = ?",
                (staging.source, user_id),
            )

            exercise_ids, open_choice, created = _resolve_exercises(
                connection, mapping, staging.exercise_names
            )

            sessions: list[dict] = []
            counts = {"workouts": 0, "exercises": 0, "sets": 0}

            for workout in staging.workouts:
                workout_id = _uuid()
                # The local calendar's start of day, stored as UTC — what the
                # app's own `calendar.startOfDay` produces, and what every "was
                # this today" lookup compares against.
                local_start = workout.start.astimezone(staging.zone)
                day = local_start.replace(hour=0, minute=0, second=0, microsecond=0)

                connection.execute(
                    """
                    INSERT INTO workout
                        (id, blockId, day, startTime, endTime, notes, usernotes, source)
                    VALUES (?, NULL, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        workout_id,
                        _grdb_date(day),
                        _grdb_date(workout.start),
                        _grdb_date(workout.end) if workout.end else None,
                        workout.title,
                        workout.notes,
                        staging.source,
                    ),
                )
                counts["workouts"] += 1

                for index, exercise in enumerate(workout.exercises):
                    exercise_id = exercise_ids[exercise.source_name]
                    row_id = _uuid()
                    entry = mapping.entries[exercise.source_name]
                    connection.execute(
                        """
                        INSERT INTO workoutExercise
                            (id, workoutId, exerciseId, groupIndex, position, variant)
                        VALUES (?, ?, ?, ?, 0, ?)
                        """,
                        # Every group holds one exercise: Strong records no
                        # superset structure, and inventing one would be a claim
                        # about how the session was performed.
                        (row_id, workout_id, exercise_id, index, entry.variant),
                    )
                    counts["exercises"] += 1

                    staged_sets = []
                    for position, logged in enumerate(exercise.sets):
                        connection.execute(
                            """
                            INSERT INTO workoutSet
                                (id, workoutExerciseId, position, reps,
                                 weightValue, weightUnit, complete, setType,
                                 durationSeconds, distanceValue, distanceUnit,
                                 rpe, usernotes)
                            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
                            """,
                            (
                                _uuid(),
                                row_id,
                                position,
                                logged.reps,
                                logged.weight,
                                logged.weight_unit,
                                logged.set_type,
                                logged.duration_seconds,
                                logged.distance,
                                logged.distance_unit,
                                logged.rpe,
                                logged.notes,
                            ),
                        )
                        counts["sets"] += 1
                        staged_sets.append(
                            {
                                "complete": True,
                                "set_type": logged.set_type,
                                "weight": logged.weight,
                                "weight_unit": logged.weight_unit,
                                "reps": logged.reps,
                            }
                        )

                    sessions.append(
                        {
                            "exercise_id": exercise_id,
                            "is_open_choice": open_choice.get(exercise_id, False),
                            "date": workout.start,
                            "sets": staged_sets,
                        }
                    )

            events = []
            if replay_maxes:
                existing = {
                    row[0]: row[1] * (0.45359237 if row[2] == "lb" else 1.0)
                    for row in connection.execute(
                        """
                        SELECT exerciseId, MAX(value), unit FROM achievedMax
                        WHERE userId = ? GROUP BY exerciseId
                        """,
                        (user_id,),
                    )
                }
                events = maxes.replay(sessions, existing)
                connection.executemany(
                    """
                    INSERT INTO achievedMax
                        (userId, exerciseId, value, unit, date, notes, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        (
                            user_id,
                            event.exercise_id,
                            event.value,
                            event.unit,
                            _grdb_date(event.date),
                            event.notes,
                            staging.source,
                        )
                        for event in events
                    ],
                )

        return Result(
            workouts=counts["workouts"],
            exercises=counts["exercises"],
            sets=counts["sets"],
            created_exercises=created,
            max_events=len(events),
            replaced=replaced,
        )
    finally:
        connection.close()

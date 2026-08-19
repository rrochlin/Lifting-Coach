"""The normalized intermediate: a training log, in no particular app's shape.

Sits between a vendor's export and this app's database so that neither knows
about the other. A new source implements a parser that produces one of these and
inherits the loader, the mapping discipline and the tests for free.

Two rules the parsers must hold to, because the loader trusts them:

- **Absence is ``None``, never zero.** Strong writes ``0.0`` in the weight
  column for a pull-up and ``0`` in the reps column for a plank. Neither is a
  measurement — one means bodyweight and the other means this set wasn't counted
  in reps — and carrying them through as numbers would put weights nobody lifted
  into a log that gets read back as fact.
- **Order is what was performed.** Sets keep the order the source listed them
  in, and so do exercises, including when the same lift appears twice in a
  session.

Timestamps are timezone-aware and normalized to UTC on the way in, since that is
what GRDB stores. Exports that carry naive wall-clock times (Strong's does) get
interpreted in an explicitly chosen zone rather than the machine's.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

# What the app's `SetType` accepts. There is deliberately no `failure` — see
# `Exercise.swift`, which spells out why: failure is RPE 10 plus forced partials
# or a weight drop, i.e. a description of what happened, not a kind of set.
SET_TYPES = ("warmup", "working", "drop")


@dataclass
class StagedSet:
    """One logged set. Every field but ``set_type`` may legitimately be absent."""

    set_type: str = "working"
    reps: int | None = None
    weight: float | None = None
    weight_unit: str | None = None
    rpe: float | None = None
    duration_seconds: float | None = None
    distance: float | None = None
    distance_unit: str | None = None
    notes: str | None = None

    def __post_init__(self) -> None:
        if self.set_type not in SET_TYPES:
            raise ValueError(f"unknown set type {self.set_type!r}")


@dataclass
class StagedExercise:
    """A contiguous run of sets performed under one of the source's names.

    ``source_name`` is the vendor's own string, untouched. Resolving it to an
    exercise is the mapping's job and happens nowhere near here.
    """

    source_name: str
    sets: list[StagedSet] = field(default_factory=list)


@dataclass
class StagedWorkout:
    start: datetime
    end: datetime | None = None
    #: The session's own title, where the source has one ("Legs").
    title: str | None = None
    #: The lifter's own note on the session.
    notes: str | None = None
    exercises: list[StagedExercise] = field(default_factory=list)

    def __post_init__(self) -> None:
        for name in ("start", "end"):
            value = getattr(self, name)
            if value is None:
                continue
            if value.tzinfo is None:
                raise ValueError(f"{name} must be timezone-aware")
            setattr(self, name, value.astimezone(timezone.utc))

    @property
    def set_count(self) -> int:
        return sum(len(exercise.sets) for exercise in self.exercises)


@dataclass
class Staging:
    """A whole log, plus the provenance tag every workout it produces carries."""

    source: str
    #: The zone the source's wall-clock timestamps were read in.
    #:
    #: Carried rather than recomputed because the loader needs it: the app's
    #: `workout.day` column is the *local* start of day, and deriving "local"
    #: from whatever machine happens to run the load would put a workout on the
    #: neighbouring calendar day depending on where you were sitting.
    timezone_name: str = "UTC"
    workouts: list[StagedWorkout] = field(default_factory=list)

    @property
    def zone(self) -> ZoneInfo:
        return ZoneInfo(self.timezone_name)

    @property
    def set_count(self) -> int:
        return sum(workout.set_count for workout in self.workouts)

    @property
    def exercise_names(self) -> list[str]:
        """Every distinct source name, in first-seen order."""
        seen: dict[str, None] = {}
        for workout in self.workouts:
            for exercise in workout.exercises:
                seen.setdefault(exercise.source_name)
        return list(seen)

    # -- JSON ---------------------------------------------------------------
    #
    # Written out rather than kept in memory so the resolve stage in the middle
    # has something concrete to read, and so a load can be re-run against
    # exactly the bytes a mapping was reviewed against.

    def to_json(self) -> str:
        def encode(value: object) -> object:
            if isinstance(value, datetime):
                return value.isoformat()
            raise TypeError(type(value))

        return json.dumps(asdict(self), indent=2, default=encode, ensure_ascii=False)

    def write(self, path: Path) -> None:
        path.write_text(self.to_json(), encoding="utf-8")

    @classmethod
    def read(cls, path: Path) -> "Staging":
        raw = json.loads(path.read_text(encoding="utf-8"))
        return cls(
            source=raw["source"],
            timezone_name=raw.get("timezone_name", "UTC"),
            workouts=[
                StagedWorkout(
                    start=datetime.fromisoformat(workout["start"]),
                    end=(
                        datetime.fromisoformat(workout["end"])
                        if workout.get("end")
                        else None
                    ),
                    title=workout.get("title"),
                    notes=workout.get("notes"),
                    exercises=[
                        StagedExercise(
                            source_name=exercise["source_name"],
                            sets=[StagedSet(**s) for s in exercise["sets"]],
                        )
                        for exercise in workout["exercises"]
                    ],
                )
                for workout in raw["workouts"]
            ],
        )

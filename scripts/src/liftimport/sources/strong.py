"""Strong's CSV export.

The whole file is deterministic. Nothing here looks at the exercise catalog,
because the one judgment this format requires — what "Squat (Barbell)" actually
*is* — belongs to the mapping stage and to a person.

What the format gets right: one row per set, in performed order, with warmup,
drop and failure sets tagged. What it doesn't say, and the caller must:

- **No unit column.** Strong exports in whatever unit the account was set to. So
  the unit is declared at the command line, not inferred from how big the
  numbers look.
- **No UTC offset.** ``Date`` is naive wall-clock, so it's interpreted in an
  explicitly chosen timezone. Getting this wrong shifts every workout onto the
  wrong calendar day, which is the exact trap ``CLAUDE.md`` documents for
  writing rows by hand.

Four ``Set Order`` values are not ordinals:

``W``
    A warmup. Straight across.
``D``
    A drop set. Straight across.
``F``
    Taken to failure. The app's ``SetType`` deliberately has no ``failure``
    case, so this becomes a working set rated **RPE 10** — but only where the
    row left RPE blank. A rating the lifter actually entered always wins over
    one inferred from a tag.
``Rest Timer``
    Not a set at all: the rest-timer *setting* for that exercise, repeated once
    per set. Dropped. The app's ``WorkoutSet.restOverride`` means "the rest I
    chose for this one set", and writing a global 120 s default into thousands
    of rows would make a preference read back as thousands of per-set decisions.
"""

from __future__ import annotations

import csv
import re
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from ..staging import Staging, StagedExercise, StagedSet, StagedWorkout

SOURCE = "strong-csv"

REST_TIMER = "Rest Timer"
_SET_TYPE_TAGS = {"W": "warmup", "D": "drop", "F": "working"}
#: The tag that carries an effort rating rather than a set type.
_FAILURE_TAG = "F"
_FAILURE_RPE = 10.0

_DURATION_PART = re.compile(r"(\d+)\s*([hms])")


def parse_duration(text: str) -> timedelta | None:
    """``"1h 5m"`` / ``"43m"`` / ``"1h"`` -> a duration.

    Returns ``None`` for anything unparseable rather than guessing, so a
    workout with a mangled duration simply has no end time instead of an
    invented one.
    """
    parts = _DURATION_PART.findall(text or "")
    if not parts:
        return None
    units = {"h": "hours", "m": "minutes", "s": "seconds"}
    return timedelta(**{units[unit]: int(value) for value, unit in parts})


def _number(text: str) -> float | None:
    """A numeric cell, where zero means *absent*.

    Strong writes ``0.0`` for a bodyweight pull-up and ``0`` for the reps of a
    plank. Neither is a measurement, and carrying them through as numbers would
    put a weight nobody lifted into the log.
    """
    text = (text or "").strip()
    if not text:
        return None
    try:
        value = float(text)
    except ValueError:
        return None
    return value if value != 0 else None


def _text(value: str) -> str | None:
    value = (value or "").strip()
    return value or None


def parse(
    path: Path,
    *,
    timezone_name: str = "America/Los_Angeles",
    weight_unit: str = "lb",
    distance_unit: str = "mi",
) -> Staging:
    """Reads a Strong export into staging, preserving performed order."""
    zone = ZoneInfo(timezone_name)

    with path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))

    workouts: list[StagedWorkout] = []
    by_start: dict[str, StagedWorkout] = {}

    for row in rows:
        order = (row.get("Set Order") or "").strip()
        if order == REST_TIMER:
            continue

        key = row["Date"]
        workout = by_start.get(key)
        if workout is None:
            start = datetime.strptime(key, "%Y-%m-%d %H:%M:%S").replace(tzinfo=zone)
            duration = parse_duration(row.get("Duration", ""))
            workout = StagedWorkout(
                start=start,
                end=start + duration if duration else None,
                title=_text(row.get("Workout Name", "")),
                notes=_text(row.get("Workout Notes", "")),
            )
            by_start[key] = workout
            workouts.append(workout)

        name = row["Exercise Name"].strip()
        # A *contiguous* run, not a lookup by name. In six of these 840 sessions
        # a lift is genuinely returned to later; grouping by name would merge
        # the two blocks and destroy the order they were actually performed in.
        if not workout.exercises or workout.exercises[-1].source_name != name:
            workout.exercises.append(StagedExercise(source_name=name))

        rpe = _number(row.get("RPE", ""))
        if order == _FAILURE_TAG and rpe is None:
            rpe = _FAILURE_RPE

        weight = _number(row.get("Weight", ""))
        distance = _number(row.get("Distance", ""))
        duration_seconds = _number(row.get("Seconds", ""))

        workout.exercises[-1].sets.append(
            StagedSet(
                set_type=_SET_TYPE_TAGS.get(order, "working"),
                reps=int(reps) if (reps := _number(row.get("Reps", ""))) else None,
                weight=weight,
                weight_unit=weight_unit if weight is not None else None,
                rpe=rpe,
                duration_seconds=duration_seconds,
                distance=distance,
                distance_unit=distance_unit if distance is not None else None,
                notes=_text(row.get("Notes", "")),
            )
        )

    return Staging(source=SOURCE, timezone_name=timezone_name, workouts=workouts)

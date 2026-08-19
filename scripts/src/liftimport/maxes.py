"""Replays achieved maxes over an imported log.

An achieved max is not a setting — it is the fact that you once lifted a weight
(Core Tenets 6). The ``achievedMax`` table is append-only event history for
exactly that reason, so importing five years of training should leave behind
five years of *progression*, not one current number.

**The rule here is a copy of ``AchievedMaxUpdate.swift``.** That's a real cost
and it is stated rather than hidden: the two must be changed together, and
``tests/test_maxes.py`` pins the guards as a table so a divergence has somewhere
to show up. The duplication exists because the app deliberately has no import
code — this pipeline writes rows the app only reads — and it goes away in phase
2, when the importer Lambda owns the rule for both.

The four guards, and why each one is there:

- **completed only** — an unfinished set is not a lift.
- **working sets only** — a warmup or a drop set isn't a maximal effort, so a
  heavy ramp-up single must not overwrite a real best.
- **never an open choice** — "Triceps extension" is not one movement, so a
  heavier weight this month than last says nothing about the same lift.
- **strictly heavier** — ties don't produce a new event. Repeating your best is
  not beating it, and recording it as one would turn the history into noise.

Reps are deliberately not used to project a higher one-rep max. 335x3 records an
achieved max of 335, not an estimate of a single; estimation is ``.theoretical``
and is a separate, still-unresolved concept.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

_TO_KG = {"kg": 1.0, "lb": 0.45359237}


def _kilograms(value: float, unit: str | None) -> float:
    """Comparison happens in kilograms; storage keeps the logged unit."""
    return value * _TO_KG.get(unit or "kg", 1.0)


@dataclass
class MaxEvent:
    exercise_id: int
    value: float
    unit: str
    date: datetime
    notes: str | None


def replay(sessions: list[dict], existing: dict[int, float] | None = None) -> list[MaxEvent]:
    """Walks the log oldest-first, emitting an event each time a best is beaten.

    ``sessions`` is a flat list of ``{exercise_id, is_open_choice, date, sets}``
    in no particular order; this sorts by date, because a progression built out
    of order would record maxes that were never records.

    ``existing`` is the best already on file per exercise, in kilograms, so an
    import onto a database that already has history doesn't re-announce a
    lighter lift as a new best.
    """
    best: dict[int, float] = dict(existing or {})
    events: list[MaxEvent] = []

    for session in sorted(sessions, key=lambda item: item["date"]):
        if session["is_open_choice"]:
            continue
        for logged in session["sets"]:
            if not logged.get("complete"):
                continue
            if logged.get("set_type") != "working":
                continue
            value = logged.get("weight")
            if value is None:
                continue

            kilograms = _kilograms(value, logged.get("weight_unit"))
            current = best.get(session["exercise_id"])
            if current is not None and current >= kilograms:
                continue

            best[session["exercise_id"]] = kilograms
            reps = logged.get("reps")
            events.append(
                MaxEvent(
                    exercise_id=session["exercise_id"],
                    value=value,
                    unit=logged.get("weight_unit") or "kg",
                    date=session["date"],
                    # Same note `AchievedMaxUpdate` writes: what the max was
                    # done for. A max at 3 reps and one at 1 are both facts, and
                    # the difference belongs on the record.
                    notes=f"{reps} rep{'' if reps == 1 else 's'}" if reps else None,
                )
            )

    return events

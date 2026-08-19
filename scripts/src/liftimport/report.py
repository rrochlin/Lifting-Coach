"""The work packet for the resolve stage.

Prepares everything a person — or, later, an agent in a Lambda — needs to decide
what each of a source's exercise names is: how much of the log it accounts for,
when it was used, the loads and reps it was actually performed with, and some
catalog entries whose names overlap.

It **proposes nothing**. The candidates are printed to be looked at, and the
decision is written by hand into the mapping file. That separation is the point:
the moment this file starts picking the top candidate, the app is guessing at
exercise identity again, which is what ``CatalogMatcher`` was deleted for.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import catalog
from .catalog import CatalogEntry
from .staging import Staging


@dataclass
class NameReport:
    name: str
    set_count: int
    session_count: int
    first_seen: str
    last_seen: str
    weights: tuple[float, float] | None
    reps: tuple[int, int] | None
    #: Sets with a duration or a distance and no reps — the tell for cardio.
    timed_sets: int
    candidates: list[CatalogEntry]
    mapped_as: str | None


def build(staging: Staging, mapped: dict[str, str] | None = None) -> list[NameReport]:
    """One report per distinct source name, heaviest usage first."""
    mapped = mapped or {}
    stats: dict[str, dict] = {}

    for workout in staging.workouts:
        day = workout.start.date().isoformat()
        for exercise in workout.exercises:
            entry = stats.setdefault(
                exercise.source_name,
                {
                    "sets": 0,
                    "days": set(),
                    "first": day,
                    "last": day,
                    "weights": [],
                    "reps": [],
                    "timed": 0,
                },
            )
            entry["sets"] += len(exercise.sets)
            entry["days"].add(day)
            entry["first"] = min(entry["first"], day)
            entry["last"] = max(entry["last"], day)
            for logged in exercise.sets:
                if logged.weight is not None:
                    entry["weights"].append(logged.weight)
                if logged.reps is not None:
                    entry["reps"].append(logged.reps)
                if logged.reps is None and (
                    logged.duration_seconds is not None or logged.distance is not None
                ):
                    entry["timed"] += 1

    reports = [
        NameReport(
            name=name,
            set_count=entry["sets"],
            session_count=len(entry["days"]),
            first_seen=entry["first"],
            last_seen=entry["last"],
            weights=(min(entry["weights"]), max(entry["weights"]))
            if entry["weights"]
            else None,
            reps=(min(entry["reps"]), max(entry["reps"])) if entry["reps"] else None,
            timed_sets=entry["timed"],
            candidates=catalog.search(name),
            mapped_as=mapped.get(name),
        )
        for name, entry in stats.items()
    ]
    reports.sort(key=lambda report: (-report.set_count, report.name))
    return reports


def render(reports: list[NameReport], *, unmapped_only: bool = False) -> str:
    lines: list[str] = []
    shown = [r for r in reports if not (unmapped_only and r.mapped_as)]

    total = sum(report.set_count for report in reports)
    covered = sum(report.set_count for report in reports if report.mapped_as)
    lines.append(
        f"{len(reports)} exercise names, {total} sets. "
        f"Mapped: {sum(1 for r in reports if r.mapped_as)} names "
        f"({covered}/{total} sets)."
    )
    lines.append("")

    for report in shown:
        head = f"{report.name}  —  {report.set_count} sets / {report.session_count} sessions"
        lines.append(head)
        lines.append(f"  seen        {report.first_seen} .. {report.last_seen}")
        if report.weights:
            lines.append(f"  weight      {report.weights[0]:g} .. {report.weights[1]:g}")
        else:
            lines.append("  weight      none logged (bodyweight or timed)")
        if report.reps:
            lines.append(f"  reps        {report.reps[0]} .. {report.reps[1]}")
        if report.timed_sets:
            lines.append(f"  timed sets  {report.timed_sets}")
        if report.mapped_as:
            lines.append(f"  MAPPED      {report.mapped_as}")
        else:
            lines.append("  candidates  (for reading, not for applying)")
            for candidate in report.candidates:
                equipment = candidate.equipment or "—"
                lines.append(
                    f"    {candidate.slug:<48} {candidate.name}  [{equipment}]"
                )
        lines.append("")

    return "\n".join(lines)

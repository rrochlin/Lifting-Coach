"""The reviewed translation from a source's exercise names to this app's.

This file is the *only* place a name becomes an exercise, and it does so by
reading a decision someone already made and wrote down — never by inspecting
the name. That's the rule in ``notes/Workout App/Concepts.md`` ("Programs name
exercises, they don't describe them"), applied to imports: whoever exported the
log knew what they were doing, so the information was never missing, and
recovering it with a keyword matcher re-derives something that was always
available to simply record.

Three outcomes, all authored:

``slug``
    This name **is** that vendored-catalog entry.
``create``
    A real, specific lift the vendored catalog doesn't contain ("Belt Squat").
    Mints a catalog row, reused by name so a reload doesn't make a second copy —
    the same thing ``ProgramLoader.resolveOpenSlots`` does for open slots.
``open_choice``
    The name states a goal, not a movement — "Triceps Extension" across 382
    sets is not one lift. Load-bearing, not cosmetic: ``AchievedMaxUpdate``
    refuses to record a max for an open choice, because a heavier weight this
    week than last says nothing when the movement may have changed.

Plus an optional ``variant``, which carries the source's own wording into
``WorkoutExercise.variant`` where it is prescription-level detail rather than
identity — "Incline bench, Smith machine" is the same lift as incline bench and
should share its history, while still reading as what was actually done.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from . import catalog

DEFAULT_PATH = Path(__file__).resolve().parents[2] / "data/strong_exercise_map.json"


class MappingError(Exception):
    """The mapping is malformed, or doesn't cover the log it's being used on."""


@dataclass(frozen=True)
class Entry:
    source_name: str
    slug: str | None = None
    variant: str | None = None
    create: dict | None = None
    open_choice: dict | None = None

    @property
    def kind(self) -> str:
        if self.slug:
            return "slug"
        return "open_choice" if self.open_choice else "create"


@dataclass
class Mapping:
    source: str
    entries: dict[str, Entry]

    def require(self, names: list[str]) -> None:
        """Fails unless every name in the log has a decision recorded.

        Aborting is the point. ``ProgramLoader`` throws on a slug the catalog
        doesn't have rather than skipping the exercise, because a plan that
        looks complete while quietly missing a day's work is the worse failure —
        and a training history is the same argument with more at stake. Half an
        import is indistinguishable from a full one once it's on the phone.
        """
        missing = [name for name in names if name not in self.entries]
        if missing:
            listed = "\n  ".join(missing)
            raise MappingError(
                f"{len(missing)} exercise name(s) have no mapping:\n  {listed}\n"
                "Add them to the mapping file. Nothing here will guess."
            )

    @classmethod
    def read(cls, path: Path | None = None) -> "Mapping":
        source_path = path or DEFAULT_PATH
        raw = json.loads(source_path.read_text(encoding="utf-8"))

        entries: dict[str, Entry] = {}
        for item in raw["entries"]:
            name = item["name"]
            if name in entries:
                raise MappingError(f"{name!r} is mapped twice")

            entry = Entry(
                source_name=name,
                slug=item.get("slug"),
                variant=item.get("variant"),
                create=item.get("create"),
                open_choice=item.get("openChoice"),
            )
            stated = [
                field
                for field in (entry.slug, entry.create, entry.open_choice)
                if field
            ]
            if len(stated) != 1:
                raise MappingError(
                    f"{name!r} must state exactly one of slug / create / openChoice"
                )
            for shape in (entry.create, entry.open_choice):
                if shape and not shape.get("muscleGroup"):
                    raise MappingError(f"{name!r} needs a muscleGroup")
                if shape and not shape.get("name"):
                    raise MappingError(f"{name!r} needs a name")
            entries[name] = entry

        return cls(source=raw["source"], entries=entries)

    def validate_against_catalog(self, path: Path | None = None) -> None:
        """Every ``slug`` must exist in the catalog the app actually ships.

        Checked here rather than at load time so a typo surfaces on a laptop
        instead of halfway through writing a phone's database.
        """
        known = catalog.load(path)
        unknown = sorted(
            entry.slug
            for entry in self.entries.values()
            if entry.slug and entry.slug not in known
        )
        if unknown:
            listed = "\n  ".join(unknown)
            raise MappingError(f"slug(s) not in the catalog:\n  {listed}")

"""Reads the vendored exercise catalog the Swift package ships.

Read-only, and read from the *same file the app imports* rather than a copy —
a mapping validated against a stale snapshot would name slugs the app doesn't
have, and would fail at load time on the phone instead of here.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

#: `scripts/` sits beside `LiftingCoachModel/` at the repo root.
CATALOG_PATH = (
    Path(__file__).resolve().parents[3]
    / "LiftingCoachModel/Sources/LiftingCoachPersistence/Resources/FreeExerciseDB.json"
)


@dataclass(frozen=True)
class CatalogEntry:
    #: `Exercise.sourceSlug` — the identity claim, unique in the app's schema.
    slug: str
    name: str
    equipment: str | None
    category: str | None
    primary_muscles: tuple[str, ...]

    @property
    def muscle_group(self) -> str:
        """What `CatalogImporter` derives, mirrored so a report can show it."""
        if not self.primary_muscles:
            return "Other"
        return self.primary_muscles[0].capitalize()


@lru_cache(maxsize=None)
def load(path: Path | None = None) -> dict[str, CatalogEntry]:
    """Every catalog entry, keyed by slug."""
    source = path or CATALOG_PATH
    entries = json.loads(source.read_text(encoding="utf-8"))
    return {
        entry["id"]: CatalogEntry(
            slug=entry["id"],
            name=entry["name"],
            equipment=entry.get("equipment"),
            category=entry.get("category"),
            primary_muscles=tuple(entry.get("primaryMuscles") or ()),
        )
        for entry in entries
    }


def search(terms: str, *, limit: int = 8, path: Path | None = None) -> list[CatalogEntry]:
    """Catalog entries sharing the most words with ``terms``.

    A **reporting** aid, and nothing more. It exists so the resolve stage has
    candidates to look at; its output is never applied to anything, because
    ranking names by word overlap is exactly the kind of guess this pipeline
    refuses to make on the lifter's behalf.
    """
    wanted = _words(terms)
    if not wanted:
        return []

    scored = []
    for entry in load(path).values():
        overlap = len(wanted & _words(entry.name))
        if overlap:
            scored.append((overlap, -len(_words(entry.name)), entry))
    scored.sort(key=lambda item: (-item[0], item[1], item[2].name))
    return [entry for _, _, entry in scored[:limit]]


def _words(text: str) -> set[str]:
    return {word for word in "".join(
        character if character.isalnum() else " " for character in text.lower()
    ).split() if len(word) > 1}

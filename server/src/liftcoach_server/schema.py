"""What version a snapshot is at, worked out from the snapshot itself.

**Nothing here refuses anything.** An earlier design had the server gate uploads
on a schema stamp the phone sent along with its request. That gate is gone, for
two reasons worth keeping written down:

- It refused nothing. The floor was `v14_cognitoSub`, and a build without that
  migration has no column to record which account it belongs to — so it cannot
  sign in, so it cannot upload. The floor was unreachable by arithmetic and the
  gate's entire runtime behaviour was to record a version.
- Refusing *newer* versions would have been worse than useless. A snapshot from
  a newer app is the ordinary consequence of a TestFlight build landing before
  a Lambda deploy. Refusing it stops backups — silently accumulating unbacked-up
  training — until somebody redeploys, which is a self-inflicted outage
  protecting nothing.

So this service stores, and *records what it found*. The marker is what makes
drift loud where it can actually hurt: phase 2.3's query tools consult
`newer_than_server` and decline to answer rather than answer a question about a
table that moved under them. A declined answer is Tenet 10; a confidently wrong
training number is not.

**The version is read out of the file, never off the request.** That is the
whole reason this module can be trusted. `KNOWN_MIGRATIONS` is not a lookup
table any more — it is the *ordering* that makes "the last applied migration"
mean something, because `grdb_migrations` is an unordered set of identifiers.
`SnapshotExporter.describe` says exactly this on the Swift side and resolves it
against the migrator's registration order; this is the same resolution, and the
list below is the same list.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

from .errors import UnreadableSnapshot

#: Every migration identifier, in registration order, mirroring
#: `LiftingCoachModel/Sources/LiftingCoachPersistence/Migrations.swift`.
#:
#: This is a second copy of something the Swift file owns, which is the shape
#: that already went wrong once in this project. It is kept honest by
#: `tests/test_schema.py`, which parses `Migrations.swift` and fails when the
#: two disagree — a test rather than a comment asking two files to be nice to
#: each other. Since the redesign it is load-bearing rather than documentary:
#: get the order wrong and a snapshot is reported at the wrong version.
KNOWN_MIGRATIONS: tuple[str, ...] = (
    "v1_core",
    "v2_exerciseCatalog",
    "v3_openChoiceExercises",
    "v4_skippedWorkouts",
    "v5_exerciseVariant",
    "v6_setRestOverride",
    "v7_exerciseSuggestions",
    "v8_dropMatchedSlug",
    "v9_userPreferredUnit",
    "v10_exerciseUnitPreference",
    "v11_setUnitOverride",
    "v12_exerciseStats",
    "v13_setDurationDistance",
    "v14_cognitoSub",
)


@dataclass(frozen=True)
class SchemaVerdict:
    """What this build makes of the migrations it found in a snapshot."""

    #: The newest migration this build recognises that was applied to the file.
    version: str
    #: True when the file also carries migrations registered after this build
    #: was deployed. `version` is then a *floor* on what the file contains, not
    #: a description of it — which is precisely why a reader should decline
    #: rather than guess.
    newer_than_server: bool
    #: The identifiers that caused it, named rather than counted. A deploy that
    #: is three migrations behind should be able to say which three from the
    #: index alone, without anyone downloading the file.
    unrecognized: tuple[str, ...] = ()


def resolve(applied: Iterable[str]) -> SchemaVerdict:
    """The version a snapshot is at, given the migrations applied to it.

    Raises `UnreadableSnapshot` when nothing in the file is recognisable. That
    is the same judgement `SnapshotExportError.noAppliedMigrations` makes on the
    device, and it means one of two things: the object isn't this app's
    database, or it is from so far in the future that not one of its migrations
    predates this deploy. Both are worth recording rather than guessing at.
    """
    present = set(applied)
    known = [identifier for identifier in KNOWN_MIGRATIONS if identifier in present]
    unrecognized = tuple(sorted(present - set(KNOWN_MIGRATIONS)))

    if not known:
        raise UnreadableSnapshot(
            "The database carries no migration this build recognises.",
            unrecognized=unrecognized,
        )

    return SchemaVerdict(
        version=known[-1],
        newer_than_server=bool(unrecognized),
        unrecognized=unrecognized,
    )

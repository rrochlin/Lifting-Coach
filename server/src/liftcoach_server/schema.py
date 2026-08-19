"""What schema versions this service will take a snapshot at, and why.

A snapshot is stamped with the last migration applied to it — `v14_cognitoSub`
today. `SnapshotExporter` reads that stamp out of the *exported* file rather
than off the live database, so it always describes the bytes being uploaded.

**The gate is a floor plus a marker, not a set of known versions.**
`Backend/Overview.md` first wrote this as "the server refuses a snapshot whose
schema version it doesn't know," by analogy with `liftimport` refusing a
database predating `v13`. The analogy doesn't hold, and following it would
build an outage:

- `liftimport` **writes**. It refuses an old database because it inserts rows
  into columns that database doesn't have. A refusal there prevents corruption.
- This service **stores, and later reads**. A snapshot from a *newer* app is
  the ordinary consequence of a TestFlight build landing before a Lambda
  deploy, and it is perfectly storable. Refusing it would mean every upload
  409s — for hours or days, silently accumulating unbacked-up training — until
  somebody redeploys. That is a self-inflicted outage protecting nothing,
  because at phase 2.1 nothing reads the file at all.

So: **refuse below the floor, accept at or above it, and record when a snapshot
is newer than this build understands.** The marker is what makes drift loud
where it can actually hurt — phase 2.3's query tools consult it and decline to
answer rather than answer a question about a table that moved under them. A
declined answer is Tenet 10 (an honest empty state); a confidently wrong
training number is not.

**The floor is `v14_cognitoSub`, and it is a fact rather than a policy.** A
build without that migration has no column to record which account it belongs
to, so it cannot sign in, so it cannot have obtained a URL to upload with.
Anything at the floor was already excluded by arithmetic; stating it here just
means a hand-crafted request gets a sentence instead of a stack trace.
"""

from __future__ import annotations

from dataclasses import dataclass

#: Every migration identifier, in registration order, mirroring
#: `LiftingCoachModel/Sources/LiftingCoachPersistence/Migrations.swift`.
#:
#: This is a second copy of something the Swift file owns, which is the shape
#: that already went wrong once in this project. It is kept honest by
#: `tests/test_schema.py`, which parses `Migrations.swift` and fails when the
#: two disagree — a test rather than a comment asking two files to be nice to
#: each other.
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

#: The oldest snapshot this service will store. See the module docstring: a
#: build older than this could not have signed in, so this is a restatement of
#: something already true, not a restriction added on top of it.
MINIMUM_SCHEMA_VERSION = "v14_cognitoSub"


@dataclass(frozen=True)
class SchemaVerdict:
    """What this service makes of a snapshot's stamp."""

    version: str
    #: True when the stamp names a migration registered after the newest one
    #: this build knows, or one it doesn't recognise at all. Stored on the
    #: snapshot's metadata so a reader can decline rather than guess.
    newer_than_server: bool


def _ordinal(version: str) -> int | None:
    try:
        return KNOWN_MIGRATIONS.index(version)
    except ValueError:
        return None


def verdict(version: str) -> SchemaVerdict:
    """Judges a snapshot's schema stamp, or refuses it.

    Raises `UnsupportedSchemaVersion` only for a version this build knows to be
    below the floor. An *unrecognised* identifier is treated as newer rather
    than as garbage, which is the right guess exactly once and harmless
    otherwise: the only source of these stamps is a build of this app, and the
    only builds this one hasn't heard of are later ones.
    """
    from .errors import UnsupportedSchemaVersion

    if not version:
        raise UnsupportedSchemaVersion("The snapshot carries no schema version.")

    position = _ordinal(version)
    if position is None:
        return SchemaVerdict(version=version, newer_than_server=True)

    floor = _ordinal(MINIMUM_SCHEMA_VERSION)
    assert floor is not None, "the floor must itself be a known migration"
    if position < floor:
        raise UnsupportedSchemaVersion(
            f"Snapshots must be written at {MINIMUM_SCHEMA_VERSION} or later; "
            f"this one is {version}.",
            minimumSchemaVersion=MINIMUM_SCHEMA_VERSION,
            schemaVersion=version,
        )

    return SchemaVerdict(version=version, newer_than_server=False)

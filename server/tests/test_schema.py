"""Resolving a version out of a snapshot, and the copy of `Migrations.swift`
that makes it possible."""

from __future__ import annotations

import re

import pytest
from conftest import REPO_ROOT

from liftcoach_server import schema
from liftcoach_server.errors import UnreadableSnapshot

MIGRATIONS_SWIFT = (
    REPO_ROOT
    / "LiftingCoachModel/Sources/LiftingCoachPersistence/Migrations.swift"
)


def test_the_migration_list_matches_the_swift_one() -> None:
    """The one place this package duplicates something Swift owns.

    `scripts/src/liftimport/maxes.py` is the same shape and its lesson was that
    comments asking two files to stay in step do not keep them in step. So this
    reads the real file. A migration added to the app and not to
    `KNOWN_MIGRATIONS` fails here, in the repo where both live, rather than as
    a snapshot silently reported at the wrong version after a deploy.

    Failing rather than skipping when the Swift file is absent is deliberate: a
    skip would hide the drift in precisely the checkout where nobody is looking
    for it.
    """
    source = MIGRATIONS_SWIFT.read_text()
    in_swift = tuple(re.findall(r'registerMigration\("([^"]+)"\)', source))

    assert in_swift, f"no migrations parsed out of {MIGRATIONS_SWIFT}"
    assert schema.KNOWN_MIGRATIONS == in_swift


def test_the_version_is_the_last_registered_one_applied() -> None:
    """`grdb_migrations` is a set, not a sequence. Handing them back in a
    scrambled order must not change the answer — which is the entire reason
    `KNOWN_MIGRATIONS` has to be in registration order."""
    scrambled = ("v9_userPreferredUnit", "v1_core", "v14_cognitoSub", "v3_openChoiceExercises")
    assert schema.resolve(scrambled).version == "v14_cognitoSub"


def test_ordering_is_by_registration_not_by_name() -> None:
    """The trap this catches is real: sorted alphabetically, `v9` comes after
    `v14`, so a lexical `max()` would report a five-migration-old snapshot as
    current."""
    verdict = schema.resolve(("v9_userPreferredUnit", "v14_cognitoSub"))
    assert verdict.version == "v14_cognitoSub"


def test_an_older_snapshot_is_reported_at_its_own_version() -> None:
    """Not refused. This service stores; refusing an old file would lose a
    backup to protect nothing."""
    verdict = schema.resolve(schema.KNOWN_MIGRATIONS[:13])
    assert verdict.version == "v13_setDurationDistance"
    assert not verdict.newer_than_server


def test_a_newer_snapshot_is_stored_and_marked() -> None:
    """A TestFlight build landing before a Lambda deploy is ordinary. It gets
    recorded, flagged, and named — so a deploy three migrations behind can say
    which three without anyone downloading the file."""
    verdict = schema.resolve(schema.KNOWN_MIGRATIONS + ("v15_somethingNew",))

    assert verdict.version == "v14_cognitoSub"
    assert verdict.newer_than_server
    assert verdict.unrecognized == ("v15_somethingNew",)


def test_nothing_recognisable_is_unreadable() -> None:
    """Either it isn't this app's database, or it's from so far ahead that not
    one migration predates this deploy. Both are worth recording rather than
    guessing at."""
    with pytest.raises(UnreadableSnapshot):
        schema.resolve(("somebody_elses_migration",))


def test_an_empty_database_is_unreadable() -> None:
    with pytest.raises(UnreadableSnapshot):
        schema.resolve(())

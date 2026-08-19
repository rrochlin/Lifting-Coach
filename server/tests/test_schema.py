"""The schema gate, and the copy of `Migrations.swift` it rests on."""

from __future__ import annotations

import re

import pytest
from conftest import REPO_ROOT

from liftcoach_server import schema
from liftcoach_server.errors import UnsupportedSchemaVersion

MIGRATIONS_SWIFT = (
    REPO_ROOT
    / "LiftingCoachModel/Sources/LiftingCoachPersistence/Migrations.swift"
)


def test_the_migration_list_matches_the_swift_one() -> None:
    """The one place this package duplicates something Swift owns.

    `scripts/src/liftimport/maxes.py` is the same shape and its lesson was
    that comments asking two files to stay in step do not keep them in step.
    So this reads the real file. A migration added to the app and not to
    `KNOWN_MIGRATIONS` fails here, in the repo where both live, rather than as
    a mystery refusal after a deploy.

    Failing rather than skipping when the Swift file is absent is deliberate:
    a skip would hide the drift in precisely the checkout where nobody is
    looking for it.
    """
    source = MIGRATIONS_SWIFT.read_text()
    in_swift = tuple(re.findall(r'registerMigration\("([^"]+)"\)', source))

    assert in_swift, f"no migrations parsed out of {MIGRATIONS_SWIFT}"
    assert schema.KNOWN_MIGRATIONS == in_swift


def test_the_floor_is_a_real_migration() -> None:
    assert schema.MINIMUM_SCHEMA_VERSION in schema.KNOWN_MIGRATIONS


def test_the_current_schema_is_accepted() -> None:
    verdict = schema.verdict("v14_cognitoSub")
    assert verdict.version == "v14_cognitoSub"
    assert not verdict.newer_than_server


def test_a_build_that_could_not_have_signed_in_is_refused() -> None:
    """Below the floor. A database without `v14_cognitoSub` has nowhere to
    record which account it belongs to, so it could not have got this far —
    the refusal is a sentence instead of a stack trace."""
    with pytest.raises(UnsupportedSchemaVersion):
        schema.verdict("v13_setDurationDistance")


def test_an_unknown_version_is_accepted_and_marked() -> None:
    """A TestFlight build landing before a Lambda deploy is ordinary, and
    refusing it would stop backups for however long the gap lasts. It goes in
    the bucket, flagged, so a reader can decline rather than guess."""
    verdict = schema.verdict("v15_somethingNew")
    assert verdict.newer_than_server


def test_a_missing_version_is_refused() -> None:
    with pytest.raises(UnsupportedSchemaVersion):
        schema.verdict("")

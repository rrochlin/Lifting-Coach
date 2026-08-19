"""Validating the mapping artifact, and the real one it ships with."""

import json
from pathlib import Path

import pytest

from liftimport import catalog
from liftimport.mapping import DEFAULT_PATH, Mapping, MappingError


def write(tmp_path, entries):
    path = tmp_path / "map.json"
    path.write_text(json.dumps({"source": "test", "entries": entries}), encoding="utf-8")
    return path


def test_an_entry_must_state_exactly_one_outcome(tmp_path):
    """slug / create / openChoice are alternatives, not a fallback chain."""
    both = write(tmp_path, [{
        "name": "X", "slug": "Barbell_Squat",
        "create": {"name": "X", "muscleGroup": "Quadriceps"},
    }])
    with pytest.raises(MappingError, match="exactly one"):
        Mapping.read(both)

    neither = write(tmp_path, [{"name": "X"}])
    with pytest.raises(MappingError, match="exactly one"):
        Mapping.read(neither)


def test_a_created_entry_needs_a_muscle_group(tmp_path):
    """`Exercise.muscleGroup` is the one always-required field on the type."""
    path = write(tmp_path, [{"name": "X", "create": {"name": "X"}}])
    with pytest.raises(MappingError, match="muscleGroup"):
        Mapping.read(path)


def test_a_name_cannot_be_mapped_twice(tmp_path):
    path = write(tmp_path, [
        {"name": "X", "slug": "Barbell_Squat"},
        {"name": "X", "slug": "Barbell_Deadlift"},
    ])
    with pytest.raises(MappingError, match="mapped twice"):
        Mapping.read(path)


def test_unknown_slugs_are_caught_on_a_laptop_not_a_phone(tmp_path):
    path = write(tmp_path, [{"name": "X", "slug": "Not_Real"}])
    with pytest.raises(MappingError, match="not in the catalog"):
        Mapping.read(path).validate_against_catalog()


def test_require_names_the_gaps(tmp_path):
    mapping = Mapping.read(write(tmp_path, [{"name": "X", "slug": "Barbell_Squat"}]))
    with pytest.raises(MappingError) as error:
        mapping.require(["X", "Y", "Z"])
    assert "Y" in str(error.value) and "Z" in str(error.value)
    mapping.require(["X"])


# -- the shipped artifact --------------------------------------------------


def test_the_strong_mapping_is_valid():
    Mapping.read().validate_against_catalog()


def test_every_slug_in_the_strong_mapping_resolves():
    """Guards the one failure the loader can't recover from at run time."""
    mapping = Mapping.read()
    known = catalog.load()
    assert all(entry.slug in known for entry in mapping.entries.values() if entry.slug)


def test_the_strong_mapping_covers_the_whole_export_if_present():
    """Skipped when the CSV isn't checked out — it's personal data, untracked."""
    from liftimport.sources.strong import parse

    csv = (
        Path(__file__).resolve().parents[2]
        / "notes/Workout App/workout_history/strong_workouts_clean.csv"
    )
    if not csv.exists():
        pytest.skip("the Strong export isn't in this checkout")

    staging = parse(csv)
    Mapping.read().require(staging.exercise_names)

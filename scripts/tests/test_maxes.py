"""The achieved-max replay.

This is a **copy of the rule in `AchievedMaxUpdate.swift`**, and this file is
where the copy is pinned. Each case below names the guard it protects, so a
change on the Swift side that isn't mirrored here has somewhere visible to fail.
The duplication is temporary by design — see `liftimport/maxes.py`.
"""

from datetime import datetime, timedelta, timezone

from liftimport.maxes import replay

DAY = timedelta(days=1)
START = datetime(2024, 1, 1, tzinfo=timezone.utc)


def session(day, sets, exercise_id=1, is_open_choice=False):
    return {
        "exercise_id": exercise_id,
        "is_open_choice": is_open_choice,
        "date": START + day * DAY,
        "sets": sets,
    }


def working(weight, reps=5, unit="lb", complete=True, set_type="working"):
    return {
        "complete": complete,
        "set_type": set_type,
        "weight": weight,
        "weight_unit": unit,
        "reps": reps,
    }


def test_each_new_best_is_its_own_event():
    """`achievedMax` is append-only history, so an import leaves a progression."""
    events = replay([
        session(0, [working(225)]),
        session(1, [working(245)]),
        session(2, [working(275)]),
    ])
    assert [e.value for e in events] == [225, 245, 275]


def test_the_log_is_walked_oldest_first():
    """Out of order, a lighter later lift would be recorded as a record."""
    events = replay([
        session(2, [working(275)]),
        session(0, [working(225)]),
        session(1, [working(245)]),
    ])
    assert [e.value for e in events] == [225, 245, 275]


def test_matching_your_best_is_not_beating_it():
    events = replay([session(0, [working(225)]), session(1, [working(225)])])
    assert len(events) == 1


def test_only_working_sets_count():
    """A heavy ramp-up single is not a maximal effort."""
    events = replay([
        session(0, [working(225)]),
        session(1, [working(315, set_type="warmup"), working(365, set_type="drop")]),
    ])
    assert [e.value for e in events] == [225]


def test_incomplete_sets_are_not_lifts():
    events = replay([session(0, [working(405, complete=False)])])
    assert events == []


def test_an_open_choice_never_records_a_max():
    """"Triceps extension" is not one movement, so heavier means nothing."""
    events = replay([session(0, [working(100)], is_open_choice=True)])
    assert events == []


def test_units_are_compared_in_kilograms_and_reported_as_logged():
    """100 kg beats 200 lb. The record keeps the unit it was lifted in."""
    events = replay([
        session(0, [working(200, unit="lb")]),
        session(1, [working(100, unit="kg")]),
    ])
    assert [(e.value, e.unit) for e in events] == [(200, "lb"), (100, "kg")]


def test_a_lighter_lift_in_another_unit_is_not_a_record():
    events = replay([
        session(0, [working(100, unit="kg")]),
        session(1, [working(200, unit="lb")]),
    ])
    assert len(events) == 1


def test_existing_history_is_respected():
    """Importing onto a database that already has maxes must not re-announce."""
    events = replay([session(0, [working(225, unit="lb")])], existing={1: 150.0})
    assert events == []


def test_bodyweight_sets_have_no_weight_to_record():
    events = replay([session(0, [working(None, reps=10)])])
    assert events == []


def test_reps_are_recorded_but_never_extrapolated():
    """335x3 records 335, not an estimate of a single. That's `.theoretical`."""
    events = replay([session(0, [working(335, reps=3)])])
    assert events[0].value == 335
    assert events[0].notes == "3 reps"
    single = replay([session(0, [working(335, reps=1)])])
    assert single[0].notes == "1 rep"


def test_exercises_are_tracked_independently():
    events = replay([
        session(0, [working(225)], exercise_id=1),
        session(0, [working(135)], exercise_id=2),
        session(1, [working(145)], exercise_id=2),
    ])
    assert sorted((e.exercise_id, e.value) for e in events) == [
        (1, 225), (2, 135), (2, 145)
    ]

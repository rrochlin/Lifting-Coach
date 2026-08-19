"""Parsing Strong's CSV. Every case here is one the real export contains."""

from datetime import timedelta
from zoneinfo import ZoneInfo

import pytest

from liftimport.sources.strong import parse, parse_duration

HEADER = (
    "Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,"
    "Distance,Seconds,Notes,Workout Notes,RPE\n"
)


def write(tmp_path, rows):
    path = tmp_path / "export.csv"
    path.write_text(HEADER + "".join(rows), encoding="utf-8")
    return path


def row(
    date="2024-01-05 17:30:00",
    name="Afternoon Workout",
    duration="1h 5m",
    exercise="Squat (Barbell)",
    order="1",
    weight="225.0",
    reps="5",
    distance="0.0",
    seconds="0.0",
    notes="",
    workout_notes="",
    rpe="",
):
    return (
        f"{date},{name},{duration},{exercise},{order},{weight},{reps},"
        f"{distance},{seconds},{notes},{workout_notes},{rpe}\n"
    )


@pytest.mark.parametrize(
    "text,expected",
    [
        ("1h 5m", timedelta(hours=1, minutes=5)),
        ("43m", timedelta(minutes=43)),
        ("2h", timedelta(hours=2)),
        ("1h 5m 30s", timedelta(hours=1, minutes=5, seconds=30)),
        ("", None),
        ("nonsense", None),
    ],
)
def test_parse_duration(text, expected):
    assert parse_duration(text) == expected


def test_workout_end_is_start_plus_duration(tmp_path):
    staging = parse(write(tmp_path, [row()]), timezone_name="America/Los_Angeles")
    workout = staging.workouts[0]
    assert workout.end - workout.start == timedelta(hours=1, minutes=5)


def test_naive_timestamps_are_read_in_the_given_zone(tmp_path):
    """The CSV states no offset, so the zone is a decision, not a discovery.

    17:30 Pacific is 01:30 UTC the following day — which is exactly why the
    loader can't derive "local" from whatever machine runs it.
    """
    staging = parse(write(tmp_path, [row()]), timezone_name="America/Los_Angeles")
    assert staging.workouts[0].start.isoformat() == "2024-01-06T01:30:00+00:00"
    assert staging.timezone_name == "America/Los_Angeles"

    utc = parse(write(tmp_path, [row()]), timezone_name="UTC")
    assert utc.workouts[0].start.isoformat() == "2024-01-05T17:30:00+00:00"


def test_rest_timer_rows_are_not_sets(tmp_path):
    """1,844 of the real export's rows are this. They are a setting, not a log."""
    path = write(
        tmp_path,
        [
            row(order="Rest Timer", weight="0.0", reps="0", seconds="120.0"),
            row(order="1"),
        ],
    )
    staging = parse(path)
    assert staging.set_count == 1
    assert staging.workouts[0].exercises[0].sets[0].reps == 5


def test_set_order_tags(tmp_path):
    path = write(
        tmp_path,
        [
            row(order="W", weight="135.0"),
            row(order="1"),
            row(order="D", weight="185.0"),
        ],
    )
    sets = parse(path).workouts[0].exercises[0].sets
    assert [s.set_type for s in sets] == ["warmup", "working", "drop"]


def test_failure_sets_become_working_at_rpe_ten(tmp_path):
    """`SetType` has no failure case by design, so the tag becomes effort."""
    logged = parse(write(tmp_path, [row(order="F")])).workouts[0].exercises[0].sets[0]
    assert logged.set_type == "working"
    assert logged.rpe == 10.0


def test_a_logged_rpe_beats_the_failure_tag(tmp_path):
    """A rating the lifter entered is data; one inferred from a tag is a guess."""
    logged = parse(write(tmp_path, [row(order="F", rpe="8.0")])).workouts[0].exercises[0].sets[0]
    assert logged.rpe == 8.0


def test_zero_weight_and_reps_are_absent_not_zero(tmp_path):
    """613 bodyweight pull-up rows say `0.0`. Nobody lifted zero pounds."""
    logged = parse(
        write(tmp_path, [row(exercise="Pull Up", weight="0.0", reps="8")])
    ).workouts[0].exercises[0].sets[0]
    assert logged.weight is None
    assert logged.weight_unit is None
    assert logged.reps == 8


def test_timed_and_distance_work(tmp_path):
    logged = parse(
        write(
            tmp_path,
            [row(exercise="Bike", weight="0.0", reps="0", distance="2.4", seconds="720.0")],
        )
    ).workouts[0].exercises[0].sets[0]
    assert logged.reps is None
    assert logged.weight is None
    assert logged.duration_seconds == 720.0
    assert logged.distance == 2.4
    assert logged.distance_unit == "mi"


def test_exercises_group_by_contiguous_run(tmp_path):
    """A lift returned to later in the session is a second block, not the same one.

    True in six of the real export's 840 sessions. Grouping by name would merge
    them and lose the order the work was actually done in.
    """
    path = write(
        tmp_path,
        [
            row(exercise="Bicep Curl (Dumbbell)"),
            row(exercise="Bench Press (Barbell)"),
            row(exercise="Bicep Curl (Dumbbell)"),
        ],
    )
    workout = parse(path).workouts[0]
    assert [e.source_name for e in workout.exercises] == [
        "Bicep Curl (Dumbbell)",
        "Bench Press (Barbell)",
        "Bicep Curl (Dumbbell)",
    ]


def test_titles_and_notes(tmp_path):
    path = write(
        tmp_path,
        [row(name="Legs", notes="felt light", workout_notes="shoulder ok")],
    )
    workout = parse(path).workouts[0]
    assert workout.title == "Legs"
    assert workout.notes == "shoulder ok"
    assert workout.exercises[0].sets[0].notes == "felt light"


def test_separate_dates_are_separate_workouts(tmp_path):
    path = write(
        tmp_path,
        [row(date="2024-01-05 17:30:00"), row(date="2024-01-07 09:00:00")],
    )
    assert len(parse(path).workouts) == 2

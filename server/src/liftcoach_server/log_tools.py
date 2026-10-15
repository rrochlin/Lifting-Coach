"""The coach reads the training log — phase 2.3's first half (INFRA-SPEC §14).

Named, read-only queries over the lifter's own snapshot: the file the phone
uploads, opened read-only from a copy in `/tmp`. **There is no SQL tool.** Each
tool is a fixed query with bounded output, so what the coach can ask is
reviewable here in one place, a question about five years of training can't
return five years of rows, and nothing the coach writes can reach the database
— it isn't opened for writing at all (Core Tenets §8).

**Every answer says how current it is.** The snapshot is a backup, uploaded
after workouts and on backgrounding; a set logged a minute ago may not be in
it. Each result starts with the upload time, and the coach is told to say so
when it matters (Tenet 10).

**A log from a newer app than this server is declined, not guessed at.** If
the snapshot carries a migration this deploy doesn't know, a table may have
moved under these queries; every tool answers that instead of a number that
might be wrong.

Dates are stored in UTC; the phone sends its time zone so they're shown in the
lifter's own days.
"""

from __future__ import annotations

import datetime
import sqlite3
from dataclasses import dataclass
from typing import Any, Callable
from zoneinfo import ZoneInfo

#: Upper bound on any one answer, in characters. A tool that would say more
#: says how much it left out.
OUTPUT_LIMIT = 6000


@dataclass(frozen=True)
class LogSnapshot:
    """An opened snapshot and what's known about it."""

    path: str
    uploaded_at: str
    #: False when the file is from a newer app than this server understands.
    readable: bool
    problem: str = ""


TOOLS: list[dict[str, Any]] = [
    {
        "name": "training_overview",
        "description": (
            "Start here when a question touches the lifter's training. Returns the span of their "
            "log, how many workouts it holds, their most recent sessions, the lifts they train most "
            "(with each lift's exercise_id, session count, last date and heaviest working set), and "
            "their current training block if they have one."
        ),
        "input_schema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "exercise_history",
        "description": (
            "Every logged set of one lift, session by session, most recent first: date, set type, "
            "weight × reps, RPE. Use it to read progress, consistency, or how hard recent work was. "
            "Get the exercise_id from training_overview or list_logged_exercises."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "exercise_id": {"type": "integer"},
                "sessions": {"type": "integer", "description": "How many recent sessions, 1–40. Default 12."},
            },
            "required": ["exercise_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "recent_workouts",
        "description": "The lifter's most recent workouts in full — every lift and every set — most recent first.",
        "input_schema": {
            "type": "object",
            "properties": {"count": {"type": "integer", "description": "1–10. Default 3."}},
            "additionalProperties": False,
        },
    },
    {
        "name": "maxes",
        "description": (
            "For each lift: the achieved max (heaviest weight actually lifted for a working set, "
            "with its date and reps) and the goal max (the number their program is written "
            "against). These are different things — never treat one as the other."
        ),
        "input_schema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "list_logged_exercises",
        "description": "Every exercise the lifter has logged, with its exercise_id and session count.",
        "input_schema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "bodyweight",
        "description": "The lifter's logged bodyweight entries, most recent first.",
        "input_schema": {
            "type": "object",
            "properties": {"count": {"type": "integer", "description": "1–60. Default 20."}},
            "additionalProperties": False,
        },
    },
]

NAMES = frozenset(tool["name"] for tool in TOOLS)


class LogReader:
    """Runs the coach's log tool calls against one snapshot, read-only."""

    def __init__(
        self, snapshot: LogSnapshot | None | Callable[[], LogSnapshot | None], time_zone: str | None = None
    ) -> None:
        # A loader, so the snapshot is fetched on the first log tool call of a
        # turn and not at all on a turn that never asks.
        self._load = snapshot if callable(snapshot) else (lambda: snapshot)
        self._loaded = False
        self._snapshot: LogSnapshot | None = None
        try:
            self._zone = ZoneInfo(time_zone) if time_zone else datetime.UTC
        except (KeyError, ValueError):
            self._zone = datetime.UTC
        self._connection: sqlite3.Connection | None = None

    def close(self) -> None:
        if self._connection is not None:
            self._connection.close()
            self._connection = None

    def run(self, name: str, tool_input: Any) -> tuple[str, bool]:
        """`(result text, is_error)` for one tool call."""
        if not self._loaded:
            self._loaded = True
            try:
                self._snapshot = self._load()
            except Exception as error:
                return f"Couldn't fetch the log right now ({type(error).__name__}). Say so; don't guess.", True
        if self._snapshot is None:
            return ("The lifter hasn't backed up their log yet, so there's nothing to read. "
                    "Ask them, or suggest signing in so the app can back it up."), False
        if not self._snapshot.readable:
            return ("Their log comes from a newer version of the app than this coach understands, so "
                    "reading it could give wrong numbers. Say you can't read it right now rather than "
                    f"guess. ({self._snapshot.problem})"), False
        args = tool_input if isinstance(tool_input, dict) else {}
        try:
            body = getattr(self, f"_{name}")(args) if name in NAMES else None
        except sqlite3.Error as error:
            return f"Couldn't read the log: {error}.", True
        if body is None:
            return f"Unknown tool {name!r}.", True
        return self._bounded(f"Log as of {self._local(self._snapshot.uploaded_at, with_time=True)}.\n\n{body}"), False

    # ── Queries ──────────────────────────────────────────────────────────────

    @property
    def _db(self) -> sqlite3.Connection:
        if self._connection is None:
            assert self._snapshot is not None
            # Read-only at the connection: the file is a copy in /tmp, and
            # nothing here could write to it even by mistake.
            self._connection = sqlite3.connect(f"file:{self._snapshot.path}?mode=ro", uri=True)
            self._connection.row_factory = sqlite3.Row
            self._connection.execute("PRAGMA query_only = ON")
        return self._connection

    def _training_overview(self, args: dict[str, Any]) -> str:
        db = self._db
        span = db.execute(
            "SELECT COUNT(*) AS n, MIN(startTime) AS first, MAX(startTime) AS last "
            "FROM workout WHERE endTime IS NOT NULL"
        ).fetchone()
        if not span["n"]:
            return "No finished workouts in the log yet."
        lines = [
            f"{span['n']} finished workouts, {self._local(span['first'])} to {self._local(span['last'])}.",
            "",
            "Most recent sessions:",
        ]
        for row in db.execute(
            "SELECT w.startTime, w.notes, "
            "  (SELECT COUNT(*) FROM workoutExercise we JOIN workoutSet s ON s.workoutExerciseId = we.id "
            "   WHERE we.workoutId = w.id AND s.complete = 1) AS sets "
            "FROM workout w WHERE w.endTime IS NOT NULL ORDER BY w.startTime DESC LIMIT 5"
        ):
            lines.append(f"- {self._local(row['startTime'])}: {row['notes'] or 'Workout'} ({row['sets']} sets)")
        lines += ["", "Lifts trained most (exercise_id — name: sessions, last, heaviest working set):"]
        for row in self._lifts(limit=25):
            lines.append(self._lift_line(row))
        block = self._current_block()
        if block:
            lines += ["", block]
        return "\n".join(lines)

    def _lifts(self, limit: int | None) -> list[sqlite3.Row]:
        query = (
            "SELECT e.id, e.name, COUNT(DISTINCT we.workoutId) AS sessions, MAX(w.startTime) AS last "
            "FROM workoutExercise we JOIN workout w ON w.id = we.workoutId JOIN exercise e ON e.id = we.exerciseId "
            "WHERE w.endTime IS NOT NULL GROUP BY e.id ORDER BY sessions DESC, e.name"
        )
        if limit:
            query += f" LIMIT {int(limit)}"
        return list(self._db.execute(query))

    def _lift_line(self, row: sqlite3.Row) -> str:
        heaviest = self._db.execute(
            "SELECT s.weightValue, s.weightUnit, s.reps FROM workoutSet s "
            "JOIN workoutExercise we ON we.id = s.workoutExerciseId JOIN workout w ON w.id = we.workoutId "
            "WHERE we.exerciseId = ? AND s.complete = 1 AND s.setType = 'working' AND s.weightValue IS NOT NULL "
            "AND w.endTime IS NOT NULL "
            "ORDER BY s.weightValue * CASE s.weightUnit WHEN 'kg' THEN 2.20462 ELSE 1 END DESC LIMIT 1",
            (row["id"],),
        ).fetchone()
        best = f", heaviest {self._weight(heaviest['weightValue'], heaviest['weightUnit'])} × {heaviest['reps']}" if heaviest else ""
        return f"- {row['id']} — {row['name']}: {row['sessions']} sessions, last {self._local(row['last'])}{best}"

    def _exercise_history(self, args: dict[str, Any]) -> str:
        exercise_id = _int(args.get("exercise_id"))
        sessions = min(max(_int(args.get("sessions"), 12), 1), 40)
        exercise = self._db.execute("SELECT name FROM exercise WHERE id = ?", (exercise_id,)).fetchone()
        if exercise is None:
            return "No exercise has that exercise_id. Use list_logged_exercises to find it."
        workouts = list(self._db.execute(
            "SELECT DISTINCT w.id, w.startTime FROM workout w JOIN workoutExercise we ON we.workoutId = w.id "
            "WHERE we.exerciseId = ? AND w.endTime IS NOT NULL ORDER BY w.startTime DESC LIMIT ?",
            (exercise_id, sessions),
        ))
        if not workouts:
            return f"{exercise['name']} has never been logged."
        lines = [f"{exercise['name']} — last {len(workouts)} sessions:"]
        for workout in workouts:
            sets = self._sets(workout["id"], exercise_id)
            lines.append(f"{self._local(workout['startTime'])}: {sets or 'no completed sets'}")
        return "\n".join(lines)

    def _recent_workouts(self, args: dict[str, Any]) -> str:
        count = min(max(_int(args.get("count"), 3), 1), 10)
        workouts = list(self._db.execute(
            "SELECT id, startTime, endTime, notes, usernotes FROM workout WHERE endTime IS NOT NULL "
            "ORDER BY startTime DESC LIMIT ?", (count,)
        ))
        if not workouts:
            return "No finished workouts in the log yet."
        out = []
        for workout in workouts:
            minutes = _minutes(workout["startTime"], workout["endTime"])
            head = f"{self._local(workout['startTime'])} — {workout['notes'] or 'Workout'}"
            if minutes:
                head += f" ({minutes} min)"
            lines = [head]
            if workout["usernotes"]:
                lines.append(f"  Lifter's note: {workout['usernotes']}")
            for exercise in self._db.execute(
                "SELECT we.exerciseId, COALESCE(we.variant, e.name) AS name, we.usernotes FROM workoutExercise we "
                "JOIN exercise e ON e.id = we.exerciseId WHERE we.workoutId = ? ORDER BY we.groupIndex, we.position",
                (workout["id"],),
            ):
                sets = self._sets(workout["id"], exercise["exerciseId"])
                lines.append(f"  {exercise['name']}: {sets or 'no completed sets'}")
                if exercise["usernotes"]:
                    lines.append(f"    Note: {exercise['usernotes']}")
            out.append("\n".join(lines))
        return "\n\n".join(out)

    def _sets(self, workout_id: str, exercise_id: int) -> str:
        parts = []
        for s in self._db.execute(
            "SELECT s.setType, s.weightValue, s.weightUnit, s.reps, s.rpe, s.durationSeconds, s.distanceValue, "
            "s.distanceUnit FROM workoutSet s JOIN workoutExercise we ON we.id = s.workoutExerciseId "
            "WHERE we.workoutId = ? AND we.exerciseId = ? AND s.complete = 1 ORDER BY we.position, s.position",
            (workout_id, exercise_id),
        ):
            parts.append(_set_text(s))
        return ", ".join(parts)

    def _maxes(self, args: dict[str, Any]) -> str:
        db = self._db
        achieved = {
            row["exerciseId"]: row for row in db.execute(
                "SELECT m.exerciseId, e.name, m.value, m.unit, m.date, m.notes FROM achievedMax m "
                "JOIN exercise e ON e.id = m.exerciseId "
                "WHERE m.rowid IN (SELECT rowid FROM achievedMax a WHERE a.exerciseId = m.exerciseId "
                "  ORDER BY a.value * CASE a.unit WHEN 'kg' THEN 2.20462 ELSE 1 END DESC, a.date DESC LIMIT 1)"
            )
        }
        goals = {
            row["exerciseId"]: row for row in db.execute(
                "SELECT g.exerciseId, e.name, g.value, g.unit, g.dateSet FROM goalMax g JOIN exercise e ON e.id = g.exerciseId"
            )
        }
        if not achieved and not goals:
            return "No achieved or goal maxes recorded."
        lines = ["exercise_id — name: achieved max (date, reps) | goal max"]
        for exercise_id in sorted(set(achieved) | set(goals), key=lambda i: (achieved.get(i) or goals.get(i))["name"]):
            a, g = achieved.get(exercise_id), goals.get(exercise_id)
            name = (a or g)["name"]
            a_text = (f"{self._weight(a['value'], a['unit'])} ({self._local(a['date'])}"
                      f"{', ' + a['notes'] if a['notes'] else ''})") if a else "none recorded"
            g_text = self._weight(g["value"], g["unit"]) if g else "none set"
            lines.append(f"- {exercise_id} — {name}: {a_text} | goal {g_text}")
        return "\n".join(lines)

    def _list_logged_exercises(self, args: dict[str, Any]) -> str:
        rows = self._lifts(limit=None)
        if not rows:
            return "Nothing logged yet."
        return "exercise_id — name: sessions\n" + "\n".join(
            f"- {r['id']} — {r['name']}: {r['sessions']}" for r in rows
        )

    def _bodyweight(self, args: dict[str, Any]) -> str:
        count = min(max(_int(args.get("count"), 20), 1), 60)
        rows = list(self._db.execute("SELECT day, value, unit FROM bodyWeight ORDER BY day DESC LIMIT ?", (count,)))
        if not rows:
            return "No bodyweight logged."
        return "\n".join(f"- {self._local(r['day'])}: {self._weight(r['value'], r['unit'])}" for r in rows)

    def _current_block(self) -> str | None:
        block = self._db.execute(
            "SELECT id, notes, startDate, endDate FROM block WHERE startDate IS NOT NULL "
            "AND startDate <= ? ORDER BY startDate DESC LIMIT 1",
            (_utc_now_text(),),
        ).fetchone()
        if block is None:
            return None
        days = self._db.execute(
            "SELECT COUNT(*) AS n FROM plannedWorkout WHERE blockId = ?", (block["id"],)
        ).fetchone()["n"]
        trained = self._db.execute(
            "SELECT COUNT(DISTINCT date(w.startTime)) AS n FROM workout w JOIN plannedWorkout p "
            "ON date(p.date) = date(w.startTime) WHERE p.blockId = ? AND w.endTime IS NOT NULL",
            (block["id"],),
        ).fetchone()["n"]
        name = block["notes"] or "Current block"
        return (f"Current block: {name}, started {self._local(block['startDate'])}"
                f"{', planned to end ' + self._local(block['endDate']) if block['endDate'] else ''}; "
                f"{days} programmed days, {trained} trained.")

    # ── Formatting ───────────────────────────────────────────────────────────

    def _local(self, stored: Any, with_time: bool = False) -> str:
        moment = _parse(stored)
        if moment is None:
            return str(stored or "unknown date")
        local = moment.astimezone(self._zone)
        return local.strftime("%a %Y-%m-%d %H:%M" if with_time else "%a %Y-%m-%d")

    @staticmethod
    def _weight(value: Any, unit: Any) -> str:
        return f"{_number(value)} {unit or 'lb'}"

    def _bounded(self, text: str) -> str:
        if len(text) <= OUTPUT_LIMIT:
            return text
        cut = text[:OUTPUT_LIMIT].rsplit("\n", 1)[0]
        return cut + f"\n… (cut off; {len(text) - len(cut)} more characters — ask for fewer sessions)"


def _set_text(s: sqlite3.Row) -> str:
    kind = {"warmup": "W ", "drop": "D "}.get(s["setType"] or "working", "")
    if s["durationSeconds"] is not None and s["weightValue"] is None:
        seconds = int(s["durationSeconds"])
        text = f"{seconds // 60}:{seconds % 60:02d}"
        if s["distanceValue"] is not None:
            text += f" · {_number(s['distanceValue'])} {s['distanceUnit'] or ''}".rstrip()
    else:
        weight = f"{_number(s['weightValue'])}{s['weightUnit'] or ''}" if s["weightValue"] is not None else "bodyweight"
        text = f"{weight}×{s['reps'] if s['reps'] is not None else '?'}"
    if s["rpe"] is not None:
        text += f" @{_number(s['rpe'])}"
    return kind + text


def _number(value: Any) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "?"
    return str(int(number)) if number == int(number) else f"{number:g}"


def _int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _parse(stored: Any) -> datetime.datetime | None:
    """GRDB's `YYYY-MM-DD HH:MM:SS.SSS`, in UTC."""
    if not stored:
        return None
    text = str(stored).replace("T", " ").rstrip("Z")
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.datetime.strptime(text, fmt).replace(tzinfo=datetime.UTC)
        except ValueError:
            continue
    return None


def _minutes(start: Any, end: Any) -> int | None:
    a, b = _parse(start), _parse(end)
    return int((b - a).total_seconds() // 60) if a and b and b > a else None


def _utc_now_text() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M:%S.000")

# scripts/

Translates external training logs into Lifting Coach's own language.

Python, managed with [uv], standard library only. It lives at the repo root
rather than under the Swift package because it is the seed of the Lambda-side
layout — the resolve and load stages are meant to lift into a function later
without being untangled from an iOS target first.

```sh
uv sync
uv run pytest
```

## The contract

Three stages, and **only the middle one is allowed to think**.

| stage | command | thinks? |
|---|---|---|
| extract | `liftimport extract` | no — deterministic, source-specific, catalog-blind |
| resolve | `liftimport report`, then a human or an agent | **yes**, once, and the result is committed |
| load | `liftimport load` / `push` | no — strict, transactional, aborts on anything unmapped |

The split exists because of the rule in `notes/Workout App/Concepts.md`:
**nothing in this project reads an exercise name and guesses what it is.** A
guess that lands wrong is worse than a failure, because it looks like data. The
same discipline already governs program loading, where the judgment happens once
in `Resources/Block1.json` rather than at runtime — `data/strong_exercise_map.json`
is that file's equivalent for imports.

`report` prints candidates. It does **not** propose. Ranking catalog names by
word overlap puts "Front Barbell Squat To A Bench" at the top of the list for
"Squat (Barbell)", which is exactly the failure mode.

## Importing a Strong export

The CSV is personal training data and is deliberately untracked; point `--csv`
at wherever yours lives.

```sh
uv run liftimport extract \
  --csv "../notes/Workout App/workout_history/strong_workouts_clean.csv" \
  --tz America/Los_Angeles --unit lb \
  -o /tmp/staging.json

# What still needs a decision. Silent when the mapping is complete.
uv run liftimport report --staging /tmp/staging.json

# Launch the app once first so it migrates the database and imports the catalog.
uv run liftimport push --staging /tmp/staging.json --target sim
uv run liftimport push --staging /tmp/staging.json --target device \
  --device 2F0D37A5-1A73-5D88-9E6A-61DFC7603A0A   # xcrun devicectl list devices
```

Neither `--tz` nor `--unit` is inferred: Strong's export states no UTC offset
and no unit, and guessing either corrupts every row it touches.

Relaunch the app afterwards — `AppEnvironment.bootstrap` rebuilds `exerciseStats`,
which is what the exercise picker's ordering and the set suggestions read.

## Things that will bite

- **The loader never creates the schema.** It requires a database the app has
  already migrated, and refuses one that predates `v13_setDurationDistance`.
  Reimplementing GRDB's migrations here is how the two silently diverge.
- **`workout.day` is the *local* start of day stored as UTC.** The staging file
  carries the extract's timezone so a load run on another machine can't shift
  every workout onto the neighbouring calendar day.
- **Re-running replaces, it doesn't append** — matched on `workout.source` and
  `achievedMax.source`. Workouts logged in the app carry no source and are never
  touched.
- **The achieved-max rule is duplicated** from `AchievedMaxUpdate.swift`. See
  `src/liftimport/maxes.py`; `tests/test_maxes.py` pins the guards so a
  divergence has somewhere to fail. Phase 2's importer Lambda is where it gets
  one home.

[uv]: https://docs.astral.sh/uv/

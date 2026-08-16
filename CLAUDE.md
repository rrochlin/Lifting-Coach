# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is
Lifting-Coach (working title "Workout App" in the design docs) — a personal iOS SwiftUI app for tracking powerlifting workouts, with a longer-term AI coach that helps author and adapt training plans. Built by and for the repo owner's own training.

**Read `notes/Workout App/Core Tenets.md` before designing anything.** It holds the principles that decide arguments, with reasoning attached. The ones most often violated by well-meaning changes: the app never adjusts a prescription on the lifter's behalf (§1); load and effort are independent axes, both first-class (§2); RPE is exertion, NOT reps-in-reserve — RIR appears nowhere in the app (§3); achieved/goal/theoretical maxes are distinct and never silently substituted (§6).

## Repo layout
- `notes/` — a synced snapshot of the design/planning vault (Obsidian). **Read these before making architectural decisions**, especially:
  - `notes/Workout App/Concepts.md` — the Swift data model (`Workout`, `Exercise`/`WorkoutExercise`, `PlannedWorkout`/`PlannedExercise`/`PlannedSet`, `WorkoutSet`, `WorkoutBlock`, `WorkoutPlan`, `User`). Source of truth for how the domain is modeled — implement against it, don't silently redesign it.
  - `notes/Workout App/Roadmap.md` — phasing. **Phase 1 (current)**: local-first SwiftUI + SQLite tracker, static/manually-authored workout plans, no backend dependency. Explicitly deferred to phase 2: Coach Conversation, AI plan generation, the full AWS backend.
  - `notes/Workout App/Backend/Overview.md` — the phase 2 AWS architecture (Cognito, API Gateway, Lambda, DynamoDB, Bedrock over websocket) and the `terraform-infrastructure` integration pattern (git subtree link, see that repo's `ONBOARDING.md`). Not relevant to phase 1 work.
  - `notes/Workout App/Design.md`, `Ideas.md` — earlier-stage brainstorming; superseded in places by `Concepts.md`/`Roadmap.md` where they conflict, but still useful for the "why" behind requirements.
  - `notes/Workout App/Features/*.md` — one doc per screen/feature, requirements-level detail.
  - `notes/FitnessAppNetworkDiagram.drawio` — a draw.io sketch of the phase 2 AWS backend (API Gateway → Lambda → DynamoDB tables: `users`, `workouts`, `conversations`, `plans`, `ws-connections`). **Not yet reconciled with `Backend/Overview.md`'s prose** — the table names here are more concrete than anything written in the doc. Cross-check before treating either as final.
- `sync-notes.sh` — copies the Obsidian vault (`~/Notes/Home/Projects/Workout App/`) into `notes/` here. **The source path is hardcoded to `/home/rob/...`** — if the vault lives elsewhere on the machine this is run from (e.g. a macOS `/Users/...` path), update the script first or `notes/` will silently go stale instead of erroring.
- `LiftingCoachModel/`, `Sources/App/`, `project.yml` — the phase 1 app. See "Project scaffold" below.

## Current state (as of this handoff)
`Concepts.md`'s data model is fleshed out and internally consistent: planned-vs-logged sets are properly split (`PlannedSet`/`WorkoutSet`, `PlannedExercise`/`WorkoutExercise`), and "current block" is derived from `startDate` rather than gated by `endDate`, so it doesn't disappear from view when a block runs long (slipped schedule, unlogged deload week).

The phase 1 project is scaffolded, the **Tracker → Planner loop is closed**, the app **runs verified on the iOS 26.3 simulator** with a dark-first HUD theme (`Sources/App/Theme/Theme.swift` — panels, readouts, one cyan accent, amber only for the live moment), and **the owner's real 12-week program is imported as the sample block** on first launch (`ProgramImporter` + the bundled `Block1.json`, extracted from `notes/Block1 Program 6day v19.xlsx`).

The model went through a design pass driven by that import (see Core Tenets): `LoadPrescription` is `.absolute | .percentOf(_, of: MaxReference)`; `EffortTarget` is a separate axis living on `PlannedExercise` with per-set override; maxes are split into achieved (event history) / goal (setting) / theoretical (derived, unimplemented). Session start materializes resolved effort into each set's `plannedFrom` snapshot.

Built: `WorkoutSession` + `WorkoutStore` + tracker UI; `PlanStore` + `UserStore` + planner UI; homepage metrics; theme; importer. 104 tests.

Achieved maxes now auto-record from logged sets (`AchievedMaxUpdate`, wired into `TrackerModel.completeSet`) — a heavier working-set weight than the current best becomes the new best, no manual entry. Bodyweight is logged explicitly via a sheet on Home (it's a distinct action, not derived). Home also has an honest "Health" placeholder (HealthKit not connected) and a minimal reverse-chronological Workout History list — deliberately not the calendar `Features/Workout History.md` specifies; that's staying deferred (low priority, other screens may still change shape under it) per explicit direction.

**`ProgramImporter` is a one-off dev tool, not a feature to extend** (see `Roadmap.md`'s deferred list) — it seeded the owner's real program as sample data and its job ends there. Don't generalize it or spend effort keeping it in sync as the model changes.

**The exercise catalog is now real** — a vendored, public-domain snapshot of `yuhonas/free-exercise-db` (~870 exercises), imported by `CatalogImporter` on first launch. Unlike `ProgramImporter`, this one *is* ongoing infrastructure, not a dev-only tool. Two pieces:
- `CatalogMatcher` (pure, in `LiftingCoachModel`) — low-grade keyword matching that enriches a manually-named exercise (program-imported or hand-typed) with a canonical entry's metadata, *without* changing its name or id. Deliberately conservative. See its doc comment before touching the matching heuristic — it documents real false positives that shaped the current approach.
- Images were **not** vendored (~90-100MB, nothing displays them yet) — see `FreeExerciseDB.LICENSE.txt` for the reasoning and how to get them later if needed.
- **Not every unmatched exercise is a matcher failure.** "Triceps (overhead ext / pushdown)," "Core (ab wheel / hanging leg raise)" — a coach naming a goal/muscle group and leaving the movement up to the lifter is normal programming, the same idea as "45 min LSS cardio." `Exercise.isOpenChoice` names this (set by `CatalogImporter` as a heuristic: nothing shared a movement word). It's load-bearing, not cosmetic — `AchievedMaxUpdate` refuses to record a max for one, since a heavier weight this week than last doesn't mean progress on the same lift. Don't try to "fix" these by matching harder; they're correctly unmatched forever.

**⚠️ A real device now holds real data (the owner's iPhone 13).** `Migrations.swift`'s `eraseDatabaseOnSchemaChange` (DEBUG-only) used to be a safe convenience because nothing real existed anywhere. It is no longer safe to edit a migration in place — GRDB will detect the phone's schema no longer matches a fresh run of the migrations and **silently wipe the phone's database** on next launch. `v2_exerciseCatalog` and `v3_openChoiceExercises` are the migrations added *after* this stopped being true, both additive (`ALTER TABLE`) for exactly this reason. Keep doing that.

Next, in rough order:
- **Profile: data export/import.** The one genuinely local part of that screen, and `Ideas.md` calls importing from other apps crucial. If/when real program import happens, it's a documented JSON/CSV schema (or the phase 2 AI coach), not a spreadsheet parser.
- **Superset authoring.** Stores and tracker handle supersets; the planner can't author one. Note the real program uses none.
- **Adherence denominator**: home counts all 644 sets of the 12-week block; should probably scope to elapsed days.
- **Real HealthKit integration** — scope (which metrics, a new page vs. Home, entitlements) is an open decision, not started. The Home placeholder just names what's missing.
- **UI test target** — simctl can't tap, so sheets, the planner editor, the rest timer, and the achieved-max banner are only verifiable by hand. Worth prioritizing: the completeSet → banner → Home-refresh path has never actually been exercised end-to-end, only its pieces individually.
- **Exercise catalog search stays substring-only.** `CatalogMatcher`'s heuristic is fine for a one-time enrichment pass but not built for interactive search over ~900 entries — if the picker needs to get smarter, that's real search work (embeddings/LLM), not a bigger keyword table.

Open items intentionally left unresolved (in the docs, not silently in the model):
- Whether `Exercise`/`WorkoutSet` need non-strength fields (cardio incline/duration/etc.) — currently barbell/strength-shaped only. May be fine for a phase 1 MVP scoped to the owner's own training (bench/squat/deadlift), but not decided as permanent scope.
- **The theoretical-max estimation model doesn't exist.** `MaxReference.theoretical` deliberately resolves to `nil` — estimating a max from logged work needs the rep-range-aware model `Ideas.md` calls for (standard formulas are explicitly distrusted there). Decide that model before the app starts predicting strength anywhere.
- `Backend/Overview.md`'s two Open Questions (S3/CloudFront for a possible web planner UI; Lambda implementation language) — both phase 2, not blocking.
- The `FitnessAppNetworkDiagram.drawio` vs. `Backend/Overview.md` table-naming mismatch noted above.

## Project scaffold
- `LiftingCoachModel/` — local Swift package, the portable core. Two targets:
  - `LiftingCoachModel` — pure domain types mirroring `Concepts.md`, no I/O, no dependencies. Derived logic lives here: `WorkoutPlan.currentBlock`/`nextBlock`, `WorkoutBlock.progress`/`restTime`, `User.resolvedWeight`.
  - `LiftingCoachPersistence` — GRDB/SQLite. `AppDatabase` opens and migrates; `Migrations.swift` holds the schema, **additive only past `v1_core`** (see the ⚠️ above — a real device now depends on this). Four stores: `ExerciseStore` (catalog), `WorkoutStore` (logged), `PlanStore` (blocks + programs), `UserStore` (lifter + maxes + bodyweight). Two importers: `ProgramImporter` (one-off, the owner's program), `CatalogImporter` (ongoing, the vendored exercise database).
  - `swift test` runs both suites with no Xcode involved — that's the point of keeping this a package. **Run it before `xcodebuild`; it's faster and catches most breakage.**
- `Sources/App/` — the SwiftUI iOS app. `AppEnvironment` is the composition root (views never build their own store or client). `Backend/BackendClient.swift` is the phase 2 seam, implemented for now by `UnavailableBackend`, which throws on every call rather than quietly returning empty data.
- `project.yml` + XcodeGen — `LiftingCoach.xcodeproj` is **generated and gitignored**. Edit `project.yml` and run `xcodegen generate`; never hand-edit the pbxproj, and don't commit it.

### Decisions made at scaffold time (not in the notes)
- **GRDB** for SQLite — real SQLite as `Backend/Overview.md` specifies, testable outside Xcode. SwiftData was rejected: it owns its own store format and would force `Concepts.md`'s structs into classes.
- **iOS 18** deployment target, **portrait iPhone only** for phase 1.
- Weights persist as value + unit symbol rather than normalizing to kg, so a set logged in pounds reads back in pounds.
- Superset nesting (`[[WorkoutExercise]]`) flattens in SQLite to `groupIndex` + `position`; rebuilding the arrays is the store's job.
- `workoutSet.plannedFrom` is a **JSON snapshot of the prescription, not a foreign key**. `Concepts.md` embeds `PlannedSet` by value and that's right for storage too: logged history is self-contained, so `Design.md`'s "never destroy historical data" holds by shape rather than by a delete rule, and a workout can be logged from a plan that was never saved. Tradeoff: prescribed values aren't queryable in SQL — fine while adherence is computed per workout in memory, revisit if plan-wide analytics need to filter on them. Regression tested.
- The tracker saves after **every** mutation, not on finish, so `fetchInProgress()` can recover a session the OS killed mid-workout.
- Tests that assert calendar-day behavior pin their `Calendar` to UTC — `Calendar.current` makes "same day" depend on the machine's timezone, which is the thing under test.
- **`LoadPrescription` persists two different ways on purpose.** In `plannedSet` it's discriminator + value across three columns, so the planner can eventually query it ("every set above 85%"). In `workoutSet.plannedFrom` it's inside the JSON snapshot, because there it's history, not a queryable plan. Don't "unify" these without deciding which need each one serves.
- Blocks load with `program` populated and `workouts` left `nil`; `PlanStore.attachingLoggedWorkouts` joins them. Opening the planner shouldn't pull in every workout ever logged.
- Phase 1 has no sign-in, so `UserStore.localUser()` creates a placeholder lifter on first launch. Phase 2's Cognito replaces the *identity*, not the storage.
- `SetType` has no `failure` case: per `Mid lift thoughts.md`, failure is RPE 10 plus forced partials or a weight drop, and Strong's sticky failure status was a real annoyance.
- `Exercise.sourceSlug` (identity, unique) and `Exercise.matchedSlug` (provenance, not unique) look similar but mean different things — don't collapse them. Two program exercises legitimately matching the same canonical entry is normal; two rows claiming to *be* the same canonical entry is a bug the unique index on `sourceSlug` exists to catch.

### Building
**The iOS build works.** It compiles and links cleanly (`** BUILD SUCCEEDED **`, universal simulator binary). Two quirks to know:

1. **Derived data must go outside the repo** — the agent sandbox denies writes to `./build/`.
2. **Use `-target`, not `-scheme`** — scheme-based builds fail destination resolution because no *runnable* simulator matches (see below).

```sh
DD=/tmp/lifting-coach-build   # anywhere outside the repo
xcodebuild -project LiftingCoach.xcodeproj -target LiftingCoach \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$DD/Products" OBJROOT="$DD/Intermediates" SHARED_PRECOMPS_DIR="$DD/PCH" build
```

Regenerate the project first if `project.yml` changed: `xcodegen generate`.

`swift test` in `LiftingCoachModel/` covers all the real logic and is the fast inner loop — run it before `xcodebuild`.

### Running it
An iOS 26.3 simulator runtime is installed, and **all five tabs have been verified on screen**. Full loop:

```sh
D=$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro' | grep -o '[0-9A-F-]\{36\}')
xcodegen generate                       # only if project.yml or files changed
# ...build as above...
xcrun simctl boot "$D"                  # no-op if already booted
xcrun simctl install "$D" "$DD/Products/Debug-iphonesimulator/LiftingCoach.app"
xcrun simctl launch "$D" com.rrochlin.LiftingCoach -initialTab plan
xcrun simctl io "$D" screenshot /tmp/shot.png
```

**Note "iPhone 17 Pro" is a device model, not an OS version** — it runs iOS 26.3. The stale iOS 17.0 runtime is also installed but nothing here can run on it (deployment target is 18).

`-initialTab home|workout|plan|history|profile` picks the starting tab. It exists because simctl can install, launch, and screenshot but **cannot tap** — without it, only Home is reachable from the command line. Interaction-dependent states (rest timer, sheets, the planned-workout editor) still can't be reached this way; that needs a UI test target, which doesn't exist yet.

**Seeding data to see populated views:** write directly to the app's SQLite.
```sh
DB="$(xcrun simctl get_app_container "$D" com.rrochlin.LiftingCoach data)/Library/Application Support/LiftingCoach/db.sqlite"
```
The container UUID **changes on reinstall**, so re-resolve it every time. GRDB stores dates as `'YYYY-MM-DD HH:MM:SS.SSS'` in **UTC**, while the app normalizes days with the *local* calendar — so a local start-of-day is e.g. `07:00:00.000` at UTC-7. Get this wrong and rows silently don't match "today". `workoutSet.plannedFrom` is Swift-encoded JSON; generate it with the real encoder rather than hand-writing it (`LoadPrescription` encodes as `{"rpe":{"_0":8}}`).

Lesson worth keeping: running the app immediately found two bugs that compiled fine — weights rounding 157.5 lb to 158 lb, and logged RPE never displaying. **Screenshot new views; don't trust a green build.**

## Working conventions from this project
- The notes docs are living working files, not archives — once a design conversation converges on a direction, implement it directly in the relevant `.md` (or, going forward, the actual Swift code). Don't leave agreed decisions sitting only in chat.
- The repo owner is newer to Swift specifically (not to programming or architecture) — double-check type names against real Foundation/Swift APIs rather than assuming (past mistakes caught: `DateTime`→`Date`, `Dict`→`Dictionary`, `Uuid`→`UUID`, a custom `Unit`/`Set` type shadowing Swift's built-ins) and flag Swift-specific idioms proactively (structs can't inherit — only classes/protocols; `Hashable`/`Equatable` requirements for dictionary keys; `Measurement<UnitMass>` over raw numbers for anything weight-related, for consistent unit handling).

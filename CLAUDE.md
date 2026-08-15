# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is
Lifting-Coach (working title "Workout App" in the design docs) — a personal iOS SwiftUI app for tracking powerlifting workouts, with a longer-term AI coach that helps author and adapt training plans. Built by and for the repo owner's own training.

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

The phase 1 project is now scaffolded — see "Project scaffold" below. The domain model and SQLite layer are real and tested; the five feature screens are honest placeholders.

**Next step: build the Workout Tracker for real.** `Roadmap.md` names it first because it's fully device-local. Everything it needs is in place: the domain types, the schema, and a worked `ExerciseStore` to copy the store pattern from.

Open items intentionally left unresolved (in the docs, not silently in the model):
- Exercise catalog/assets are TBD — see `Concepts.md`'s TODO section (Strong/Heavy asset sourcing as an internal-use placeholder, swap before any public release). `ExerciseCatalog.seed` is a 10-entry hardcoded stand-in until then.
- Whether `Exercise`/`WorkoutSet` need non-strength fields (cardio incline/duration/etc.) — currently barbell/strength-shaped only. May be fine for a phase 1 MVP scoped to the owner's own training (bench/squat/deadlift), but not decided as permanent scope.
- **RPE is rep-range-blind.** `LoadPrescription.rpe` carries a bare `Float`, but per `Mid lift thoughts.md` an RPE on a triple and an RPE on a set of 10 aren't the same instrument. `User.resolvedWeight` deliberately returns `nil` for `.rpe` rather than guessing — resolving it needs historical set data and a rep-range-aware model. Decide the shape before the tracker starts suggesting weights.
- `Backend/Overview.md`'s two Open Questions (S3/CloudFront for a possible web planner UI; Lambda implementation language) — both phase 2, not blocking.
- The `FitnessAppNetworkDiagram.drawio` vs. `Backend/Overview.md` table-naming mismatch noted above.

## Project scaffold
- `LiftingCoachModel/` — local Swift package, the portable core. Two targets:
  - `LiftingCoachModel` — pure domain types mirroring `Concepts.md`, no I/O, no dependencies. Derived logic lives here: `WorkoutPlan.currentBlock`/`nextBlock`, `WorkoutBlock.progress`/`restTime`, `User.resolvedWeight`.
  - `LiftingCoachPersistence` — GRDB/SQLite. `AppDatabase` opens and migrates; `Migrations.swift` holds the append-only schema; `ExerciseStore` is the one fully-wired store and the pattern to copy for workouts/plans/blocks.
  - `swift test` runs both suites with no Xcode involved — that's the point of keeping this a package. **Run it before `xcodebuild`; it's faster and catches most breakage.**
- `Sources/App/` — the SwiftUI iOS app. `AppEnvironment` is the composition root (views never build their own store or client). `Backend/BackendClient.swift` is the phase 2 seam, implemented for now by `UnavailableBackend`, which throws on every call rather than quietly returning empty data.
- `project.yml` + XcodeGen — `LiftingCoach.xcodeproj` is **generated and gitignored**. Edit `project.yml` and run `xcodegen generate`; never hand-edit the pbxproj, and don't commit it.

### Decisions made at scaffold time (not in the notes)
- **GRDB** for SQLite — real SQLite as `Backend/Overview.md` specifies, testable outside Xcode. SwiftData was rejected: it owns its own store format and would force `Concepts.md`'s structs into classes.
- **iOS 18** deployment target, **portrait iPhone only** for phase 1.
- Weights persist as value + unit symbol rather than normalizing to kg, so a set logged in pounds reads back in pounds.
- Superset nesting (`[[WorkoutExercise]]`) flattens in SQLite to `groupIndex` + `position`; rebuilding the arrays is the store's job.
- `workoutSet.plannedFromId` is `ON DELETE SET NULL`, never cascade — editing a plan must never delete what was actually lifted (the safety requirement in `Design.md`). There's a regression test for exactly this.
- `SetType` has no `failure` case: per `Mid lift thoughts.md`, failure is RPE 10 plus forced partials or a weight drop, and Strong's sticky failure status was a real annoyance.

### Environment gotcha
This machine's Xcode 26.3 has not completed its first-launch setup, so **`xcodebuild` cannot build any iOS target** — it fails loading `IDESimulatorFoundation`, and `simctl` hangs. Fix with `sudo xcodebuild -runFirstLaunch` (needs an admin password, so it can't be run unattended). Until then, `swift test` works fine, and app sources can be typechecked against the macOS SDK as a fallback.

## Working conventions from this project
- The notes docs are living working files, not archives — once a design conversation converges on a direction, implement it directly in the relevant `.md` (or, going forward, the actual Swift code). Don't leave agreed decisions sitting only in chat.
- The repo owner is newer to Swift specifically (not to programming or architecture) — double-check type names against real Foundation/Swift APIs rather than assuming (past mistakes caught: `DateTime`→`Date`, `Dict`→`Dictionary`, `Uuid`→`UUID`, a custom `Unit`/`Set` type shadowing Swift's built-ins) and flag Swift-specific idioms proactively (structs can't inherit — only classes/protocols; `Hashable`/`Equatable` requirements for dictionary keys; `Measurement<UnitMass>` over raw numbers for anything weight-related, for consistent unit handling).

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
- No application code yet as of this commit — phase 1 SwiftUI/Xcode work hasn't started.

## Current state (as of this handoff)
`Concepts.md`'s data model is fleshed out and internally consistent: planned-vs-logged sets are properly split (`PlannedSet`/`WorkoutSet`, `PlannedExercise`/`WorkoutExercise`), and "current block" is derived from `startDate` rather than gated by `endDate`, so it doesn't disappear from view when a block runs long (slipped schedule, unlogged deload week).

Next step: turn the model into an actual Xcode project — a SwiftUI app target, plus a local Swift package for the model layer (keeps `swift test` usable independent of Xcode, keeps the model portable). SwiftUI/Xcode work requires macOS; there's no Linux equivalent for previews or the simulator.

Open items intentionally left unresolved (in the docs, not silently in the model):
- Exercise catalog/assets are TBD — see `Concepts.md`'s TODO section (Strong/Heavy asset sourcing as an internal-use placeholder, swap before any public release).
- Whether `Exercise`/`WorkoutSet` need non-strength fields (cardio incline/duration/etc.) — currently barbell/strength-shaped only. May be fine for a phase 1 MVP scoped to the owner's own training (bench/squat/deadlift), but not decided as permanent scope.
- `Backend/Overview.md`'s two Open Questions (S3/CloudFront for a possible web planner UI; Lambda implementation language) — both phase 2, not blocking.
- The `FitnessAppNetworkDiagram.drawio` vs. `Backend/Overview.md` table-naming mismatch noted above.

## Working conventions from this project
- The notes docs are living working files, not archives — once a design conversation converges on a direction, implement it directly in the relevant `.md` (or, going forward, the actual Swift code). Don't leave agreed decisions sitting only in chat.
- The repo owner is newer to Swift specifically (not to programming or architecture) — double-check type names against real Foundation/Swift APIs rather than assuming (past mistakes caught: `DateTime`→`Date`, `Dict`→`Dictionary`, `Uuid`→`UUID`, a custom `Unit`/`Set` type shadowing Swift's built-ins) and flag Swift-specific idioms proactively (structs can't inherit — only classes/protocols; `Hashable`/`Equatable` requirements for dictionary keys; `Measurement<UnitMass>` over raw numbers for anything weight-related, for consistent unit handling).

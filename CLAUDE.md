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

The phase 1 project is scaffolded, the **Tracker → Planner loop is closed**, the app **runs verified on the iOS 26.3 simulator** with a dark-first HUD theme (`Sources/App/Theme/Theme.swift` — panels, readouts, one cyan accent, amber only for the live moment), and **the owner's real 12-week program is loaded as the sample block** on first launch (`ProgramLoader` + the bundled `Block1.json`, hand-translated from `notes/Block1 Program 6day v19.xlsx`).

The model went through a design pass driven by that import (see Core Tenets): `LoadPrescription` is `.absolute | .percentOf(_, of: MaxReference)`; `EffortTarget` is a separate axis living on `PlannedExercise` with per-set override; maxes are split into achieved (event history) / goal (setting) / theoretical (derived, unimplemented). Session start materializes resolved effort into each set's `plannedFrom` snapshot.

Built: `WorkoutSession` + `WorkoutStore` + tracker UI; `PlanStore` + `UserStore` + planner UI; homepage metrics; theme; catalog import + program loading. 159 tests.

Achieved maxes now auto-record from logged sets (`AchievedMaxUpdate`, wired into `TrackerModel.completeSet`) — a heavier working-set weight than the current best becomes the new best, no manual entry. Bodyweight is logged explicitly via a sheet on Home (it's a distinct action, not derived) — though that sheet is still a plain `Form` with a text field, not the wheel selector `Feedback.md` asks for (it does at least open on the lifter's own unit now). Home's today card is a **button that switches to the Workout tab** (`HomeView.onOpenWorkout`, wired to `RootView`'s tab selection); it deliberately doesn't *start* the session, because starting writes a real in-progress workout and a stray tap on a home screen shouldn't. The Workout tab stays the only owner of session state. Home also has an honest "Health" placeholder (HealthKit not connected) and a minimal reverse-chronological Workout History list — deliberately not the calendar `Features/Workout History.md` specifies; that's staying deferred (low priority, other screens may still change shape under it) per explicit direction.

**⚠️ Nothing in this codebase matches exercise names to exercises. Don't add it back.** A program says which exercise it means — either by naming a catalog entry outright, or by declaring the slot open and letting the lifter fill it. See Concepts.md's "Programs name exercises, they don't describe them" for the full reasoning; the short version is that a plan is *authored*, so whether a slot means one specific lift or the lifter's choice was never unknown, and inferring it later re-derives something that was always available to record. A keyword matcher (`CatalogMatcher`) used to do this and was deleted along with `Exercise.matchedSlug` and `CatalogImporter`'s reconcile pass.

**The bundled program is a hand translation, and that's the pattern for any future import.** `Resources/Block1.json` is the owner's spreadsheet rendered into the app's own language: exercises named by catalog slug, open slots declared with their muscle group and suggested movements, loads as `absolute` / `percentOfGoal`, effort as RPE. The judgment calls happened once, by a person ("is 'Incline press (BB or DB)' one lift or the lifter's choice?" — the latter), and are recorded in the file rather than recomputed. `ProgramLoader` transcribes it and **throws on a slug the catalog doesn't have** rather than skipping the exercise, because a plan that looks complete while quietly missing a day's work is the worse failure.

**The exercise catalog is real** — a vendored, public-domain snapshot of `yuhonas/free-exercise-db` (~870 exercises), imported by `CatalogImporter` on first launch. This is ongoing infrastructure, not a dev-only tool.
- Images were **not** vendored (~90-100MB, nothing displays them yet) — see `FreeExerciseDB.LICENSE.txt` for the reasoning and how to get them later if needed.
- **`Exercise.isOpenChoice` is authored, never inferred.** "Triceps," "Core," "Cardio" — a coach naming a goal and leaving the movement up to the lifter is normal programming. It's load-bearing, not cosmetic: `AchievedMaxUpdate` refuses to record a max for one, since a heavier weight this week than last doesn't mean progress on the same lift. An inferred flag would let a correctly-programmed lift with an odd name silently stop tracking maxes — which is exactly what the old name-matching heuristic risked.
- **`Exercise.suggestions`** carries what the program floated for an open slot ("Overhead extension," "Pushdown"). The tracker's picker shows them as shortcuts into search under a "programmed as" rail. Suggestions, **not** a whitelist — the app never refuses a choice (Core Tenets §1).

**The iPhone 13 is a dev device and its data is expendable** — the owner's explicit call. That relaxes a constraint this file used to state in the strongest terms: `eraseDatabaseOnSchemaChange` (DEBUG-only) wiping the phone was treated as a disaster, so `v2_exerciseCatalog` through `v7_exerciseSuggestions` are all strictly additive. It isn't a disaster any more, and `v8_dropMatchedSlug` is deliberately non-additive. `v9_userPreferredUnit` is back to additive (a column with a default).

Still prefer appending over editing: an erase throws away whatever you were mid-way through testing, and the flag stops being a safety net the day phase 2 puts this on a phone that matters. **Additive is the habit, not the rule** — a schema change worth making is worth making.

Wiping the phone is `xcrun devicectl device uninstall app --device <id> com.rrochlin.LiftingCoach` (see "Deploying to the phone" below), which is also the only way to make it re-bootstrap the sample block: `AppEnvironment` loads a program only when the plan has no blocks at all.

**The Workout Planner is reworked** to close the `notes/Feedback.md` Plan items. Two files now: `WorkoutPlannerView.swift` (block overview) and `PlannedWorkoutEditor.swift` (day authoring).
- The block overview shows each day's **actual prescription** — reps, resolved weight, RPE — rather than a set count you had to tap through. Days group into collapsible **weeks** (`WorkoutBlock.programmedWeeks`), with the current week open by default; a flat list of a 12-week block's ~70 days is unreadable.
- The day editor is **draft-based** (`PlannedWorkoutDraft` in the model package): edits accumulate and land on an explicit **Save**, with a confirm on the way out. This is the deliberate opposite of the tracker, which saves after every mutation so an OS kill mid-workout is recoverable — planning is authoring, and a half-typed percentage shouldn't become the plan. `hasUnsavedChanges` compares structurally, so typing a value and typing it back doesn't warn.
- Load and effort are now authorable: a mode menu (lb / kg / % of goal / % of achieved) beside the number field, exercise-level RPE with per-set override, rest written per exercise. `.theoretical` is deliberately absent from the mode menu — it resolves to `nil` by design, so offering it would let someone author a prescription that can never produce a weight.
- The "tapping the title adds a set" bug was structural: every button in an exercise shared one `List` row. Each set is its own row now, which also puts swipe-to-delete on the set rather than the whole exercise.

**`PlannedExercise.variant` / `WorkoutExercise.variant`** (migration `v5_exerciseVariant`) — the plan's own wording for a lift, e.g. "Bench press — heavy (paused, comp grip)". Needed once the program resolved onto canonical catalog entries: Monday prescribes heavy paused bench *and* its back-off sets, both correctly the same `Exercise`, which without this rendered as one exercise listed twice. `displayName` is `variant ?? exercise.name`. It is prescription, never identity — nothing keys off it. See Concepts.md's "Variant vs. exercise".

**Units are a reading preference (`User.preferredUnit`, migration `v9_userPreferredUnit`).** lb or kg, switched on Profile, applied by converting on the way to the screen.
- **Switching rewrites nothing.** Every logged set keeps the unit it was entered in; `UserStore.setPreferredUnit` touches one column. Converting the tables would round every historical row and make a display choice destructive. The Profile copy says this out loud, because a lifter who thinks the button rewrites their log won't press it.
- **`Measurement.expressed(in:)` rounds a conversion to a tenth and leaves an unconverted weight exactly alone.** The second decimal of a converted weight is noise — it wrapped Home's max readout onto two lines and, in the tracker (where the same value is *edited*), got written back on the first commit. A tenth is more than ten times finer than the smallest plate.
- **The planner is deliberately asymmetric.** An authored absolute load keeps the unit it was written in — `LoadModeMenu` is where lb/kg is chosen for a *prescription*, and the plan means what it says. A derived weight (72% of a 495 lb goal) reads in the lifter's unit like everything else; that split lives in `PlannerModel.resolvedWeight`.
- `WeightUnit` is two cases, not all of `UnitMass`, and its raw values are the symbols weights are already stored under.

**Every quantity a lifter can change is drawn as a field** — `editableField(isActive:)` plus `FieldCaret` in `Theme.swift`. Reps, weight, RPE, rest, the planner's load mode, and the running rest clock all wear one outlined, thumb-height box, and anything that opens a picker carries a caret. Before this they were quiet filled rectangles with no edge, which made an editable RPE look exactly like the annotation text beside it — the complaint was "the rest timer and RPE sections don't look clearly editable," and it was correct. `Theme.fieldEdge` is brighter than `hairline` on purpose: structural rules can be felt rather than seen, an "you can change this" outline can't. An unset RPE now reads "RPE" rather than "—", which is how Strong and Hevy label an empty field.

**Rest is per set, and tunable.** `WorkoutSet.restOverride` (migration `v6_setRestOverride`) is the lifter's own rest for one set; `WorkoutSession.restTarget(afterSetWith:)` resolves override → `plannedFrom.restTime` → block default → app default, and `prescribedRest(afterSetWith:)` is the same chain without the override, so "back to prescribed" has an answer.
- **A separate field from `plannedFrom.restTime` on purpose.** The snapshot is what the program asked for; writing a lifter's 3:30 into it would make it read back later as prescription. Also separate from the legacy `restTime` column beside it, which holds *measured* rest — mixing chosen durations into it would make old rows uninterpretable.
- Edited through `RestControl` — see below. It's shared: the tracker writes `restOverride`, the planner writes `PlannedSet.restTime` per set. The planner's exercise-level `RestMenu` still writes every set at once, which is the common case, and is the one rest control that *isn't* `RestControl` (different scope — every set at once — but worth revisiting).
- **Tuning a set does not touch a rest period already counting down** — the timer is *this* rest, the set's value is the next one. The timer's own ±30 is how you change what's on the clock.

**The RPE selector is `RPEPicker`, not a menu.** The old `Menu` over all nineteen values from 1 to 10 was complete and unusable: a scrolling list of bare numbers with no indication what any meant. The replacement is the scale as a scale — one row per whole number with its half-step beside it, each row labeled with the owner's own anchor word (10 failure, 9 all-out, 8 exertion, 7 some effort, 6 easy), and a header that says "how hard the set was — not reps left." **That labeling is load-bearing, not decoration** (Core Tenets §3): a control spelling out "8 — exertion" can't be misread as RIR the way a bare number list invites. 1–5.5 is valid and reachable behind a disclosure, but doesn't get half the control for a range a lifting log never uses. Used by both the tracker and the planner (exercise-level and per-set).

**Rest is prescribed, never measured.** `WorkoutSession.completeSet` used to record `restTime` as the gap between two completion timestamps; it doesn't any more, on the owner's call. That number is rest *plus* reaching for the phone — biased long every single time, so it looked like data while being systematically wrong. `WorkoutSet.restTime` stays as a legacy column (real rows on the phone carry values) but nothing writes it; the tracker's per-set control reads the prescription in `plannedFrom` unless `restOverride` says otherwise. See Concepts.md's "Rest is prescribed, not measured" before adding any rest analytics.

**There is exactly one rest control — `RestControl` (`Sources/App/Components/`) — and one line of it under every set.** `.prescription` is the rest that follows that set; `.running` is that same line counting down. **Colour is what separates them, not layout**: inactive is quiet ink with a small clock and no track, active is amber with a big clock and a track draining under it, complete is cyan.
- This replaced **three** surfaces that could all be on screen at once (see `notes/feedback/timer_issue.jpeg`): a chip on every set row, the popover that chip opened, and a countdown block carrying its own copy of the same buttons. `RestPicker` is deleted; nothing opens a popover for rest any more. If you're adding a fourth way to edit rest, don't.
- **Collapsed until asked.** All that shows is `REST ——— 2:00`; a running rest just runs. Tapping opens ±30/±15, the presets, and the one action that applies, growing rather than blinking in. Expiry opens it once — a REST COMPLETE readout with no way to acknowledge it is a dead end — and that's a **latch, not a derived value**, because the lifter has to be able to close it again.
- **A running clock shows nothing but the clock.** Rest proceeds unmolested: while it counts down there are no steppers and no presets, just the time and the track draining under it — two thin rows. Tapping opens the editing interface (the same rows the `.prescription` state shows, since they're the same control) and tapping again puts them away, growing and shrinking rather than appearing. Everything is still inline; it's simply not all on screen at once, and there's no longer a presentation hanging off a view that rebuilds every second.
- **Expiry opens itself**, and that's *derived* from `hasExpired` rather than latched into the expand flag — a rest of zero seconds is already over before the view exists, so nothing would observe the change and REST COMPLETE would sit there with no way to acknowledge it.
- **Three rows, not four**: the action ("SKIP" / "DONE" / "RESET 2:00") rides on the stepper row. Inline under a set, every row costs screen the lifter would rather spend on the next set.
- **Efficiency is load-bearing here.** The `TimelineView` wraps *only* the clock and its track — not the dozen buttons around them — and the whole timeline is dropped once `RestTimer.hasExpired` latches, because redrawing 0:00 once a second until someone dismisses it is a phone warming up to say nothing. Static state reads `hasExpired` rather than the current second for the same reason.

The rest of the machinery: `RestTimer` (model package, pure) + `TrackerModel`'s orchestration.
- It renders **directly under the set that started it** (`RestTimer.setID`), nested inside that set's row rather than as a row of its own — so it survives a reorder welded to its set, and the set's swipe-to-delete still targets the set. Rest is per set and tunable per set; a countdown at the top of the screen or at the foot of the exercise leaves the lifter working out which set it belongs to, which on a back-off ladder is a real question. If the triggering set is deleted mid-countdown the timer falls back to the foot of the exercise rather than vanishing.
- It **stops at zero**. `Text(timerInterval:countsDown:)` counts straight past into negative time, which turns a rest timer into a stopwatch measuring lateness; the control renders from the clock instead, and flips to a cyan REST COMPLETE state.
- It's **adjustable and skippable**, because rest is a prescription the lifter may depart from (Core Tenets §1). Shortening below the elapsed time lands on zero, never negative.
- **Presets set the clock directly** (`RestTimer.setRemaining` / `TrackerModel.setRestRemaining`), while ± goes through `RestTimer.adjust`, which clamps against elapsed time and moves the bar's denominator with it. `startedAt` stays put either way, so the track still measures this rest from when it actually began.
- `RestTimer` stores the *window* (`startedAt`/`endsAt`), not a tick count, so a phone that slept through the rest period shows the truth on return with nothing to catch up. Not persisted — a rest period spanning a relaunch is over.
- **Expiry notifies**: `RestNotifier` schedules one local notification (fixed identifier, so re-scheduling replaces rather than stacks) and cancels it on skip/finish/discard. Authorization is requested at the first rest period, not at launch. `installForegroundPresentation()` in `LiftingCoachApp.init` is what lets the banner show while the app is frontmost — the default is to suppress it, which is backwards for a phone sitting face-down on a bench with the tracker open. Not `.timeSensitive`: that needs an entitlement this signing setup doesn't have.

Next, in rough order:
- **Profile: data export/import.** The one genuinely local part of that screen still missing — the screen itself is now themed and hosts the unit switcher. `Ideas.md` calls importing from other apps crucial. If/when real program import happens, it's a documented JSON/CSV schema (or the phase 2 AI coach), not a spreadsheet parser.
- **Superset authoring.** Stores and tracker handle supersets; the planner can't author one. Note the real program uses none.
- **Adherence denominator**: home counts all 698 sets of the 12-week block; should probably scope to elapsed days.
- **Real HealthKit integration** — scope (which metrics, a new page vs. Home, entitlements) is an open decision, not started. The Home placeholder just names what's missing.
- **UI test target** — simctl can't tap, so sheets, popovers, and the achieved-max banner are only verifiable by hand. (Stopgap that worked for the `RPEPicker` popover: temporarily default `isPresented` to `true` behind a one-shot latch, build, screenshot, revert. It caught two real wrapping bugs — a "2:00" readout split across two lines and a wrapped section title — that a green build showed nothing of.) (`-openPlanDay N` and `-restDemo <seconds>` are the same kind of stopgap as `-initialTab`: the first gets the planner's day editor on screen, the second puts a running rest timer there — `-restDemo 0` lands on the expired state. The planner's Save/discard flow and `RestControl`'s own buttons still aren't exercisable.) Worth prioritizing: the completeSet → banner → Home-refresh path has never actually been exercised end-to-end, only its pieces individually.
- **The rest-complete notification is unverified.** Scheduling, cancelling, and the foreground-presentation delegate are all written and the permission prompt is confirmed to appear, but nothing here can tap "Allow", so no alert has ever actually been *seen* firing. First thing to check by hand on the phone.
- **Exercise catalog search stays substring-only.** Fine for now over ~900 entries; if the picker needs to get smarter that's real search work (embeddings/LLM), not a keyword table. Note this is about *searching* the catalog, which is a live user action — it is not a reason to reintroduce name-matching into program loading.

Open items intentionally left unresolved (in the docs, not silently in the model):
- Whether `Exercise`/`WorkoutSet` need non-strength fields (cardio incline/duration/etc.) — currently barbell/strength-shaped only. May be fine for a phase 1 MVP scoped to the owner's own training (bench/squat/deadlift), but not decided as permanent scope.
- **The theoretical-max estimation model doesn't exist.** `MaxReference.theoretical` deliberately resolves to `nil` — estimating a max from logged work needs the rep-range-aware model `Ideas.md` calls for (standard formulas are explicitly distrusted there). Decide that model before the app starts predicting strength anywhere.
- `Backend/Overview.md`'s two Open Questions (S3/CloudFront for a possible web planner UI; Lambda implementation language) — both phase 2, not blocking.
- The `FitnessAppNetworkDiagram.drawio` vs. `Backend/Overview.md` table-naming mismatch noted above.

## Project scaffold
- `LiftingCoachModel/` — local Swift package, the portable core. Two targets:
  - `LiftingCoachModel` — pure domain types mirroring `Concepts.md`, no I/O, no dependencies. Derived logic lives here: `WorkoutPlan.currentBlock`/`nextBlock`, `WorkoutBlock.progress`/`restTime`/`programmedWeeks`, `User.resolvedWeight`, `PlannedExercise.setGroups`. The two editing models are here too and are the pair to understand before touching either screen: `WorkoutSession` (tracker, saves every mutation) and `PlannedWorkoutDraft` (planner, saves on demand).
  - `LiftingCoachPersistence` — GRDB/SQLite. `AppDatabase` opens and migrates; `Migrations.swift` holds the schema, currently through `v9_userPreferredUnit` — **additive by habit past `v1_core`** (see the dev-device paragraph above; `v8` is the one deliberate exception). Four stores: `ExerciseStore` (catalog), `WorkoutStore` (logged), `PlanStore` (blocks + programs), `UserStore` (lifter + maxes + bodyweight). Plus `CatalogImporter` (the vendored exercise database) and `ProgramLoader` (a block written in the app's language — see `Resources/Block1.json`).
  - `swift test` runs both suites with no Xcode involved — that's the point of keeping this a package. **Run it before `xcodebuild`; it's faster and catches most breakage.**
- `Sources/App/` — the SwiftUI iOS app. `AppEnvironment` is the composition root (views never build their own store or client). `Components/` holds controls shared by more than one screen (`RPEPicker`, `RestControl`); `Theme/Theme.swift` holds the visual primitives (`Panel`, `Chip`, `SectionLabel`, the grouped-row modifiers). `Backend/BackendClient.swift` is the phase 2 seam, implemented for now by `UnavailableBackend`, which throws on every call rather than quietly returning empty data.
- `project.yml` + XcodeGen — `LiftingCoach.xcodeproj` is **generated and gitignored**. Edit `project.yml` and run `xcodegen generate`; never hand-edit the pbxproj, and don't commit it.

### Decisions made at scaffold time (not in the notes)
- **GRDB** for SQLite — real SQLite as `Backend/Overview.md` specifies, testable outside Xcode. SwiftData was rejected: it owns its own store format and would force `Concepts.md`'s structs into classes.
- **iOS 18** deployment target, **portrait iPhone only** for phase 1.
- Weights persist as value + unit symbol rather than normalizing to kg, so a set logged in pounds is still a pounds row on disk. What a lifter *reads* is `User.preferredUnit` — see the units paragraph above; storage fidelity and display preference are separate concerns and this decision is about the first one.
- Superset nesting (`[[WorkoutExercise]]`) flattens in SQLite to `groupIndex` + `position`; rebuilding the arrays is the store's job.
- `workoutSet.plannedFrom` is a **JSON snapshot of the prescription, not a foreign key**. `Concepts.md` embeds `PlannedSet` by value and that's right for storage too: logged history is self-contained, so `Design.md`'s "never destroy historical data" holds by shape rather than by a delete rule, and a workout can be logged from a plan that was never saved. Tradeoff: prescribed values aren't queryable in SQL — fine while adherence is computed per workout in memory, revisit if plan-wide analytics need to filter on them. Regression tested.
- The tracker saves after **every** mutation, not on finish, so `fetchInProgress()` can recover a session the OS killed mid-workout.
- Tests that assert calendar-day behavior pin their `Calendar` to UTC — `Calendar.current` makes "same day" depend on the machine's timezone, which is the thing under test.
- **`LoadPrescription` persists two different ways on purpose.** In `plannedSet` it's discriminator + value across three columns, so the planner can eventually query it ("every set above 85%"). In `workoutSet.plannedFrom` it's inside the JSON snapshot, because there it's history, not a queryable plan. Don't "unify" these without deciding which need each one serves.
- Blocks load with `program` populated and `workouts` left `nil`; `PlanStore.attachingLoggedWorkouts` joins them. Opening the planner shouldn't pull in every workout ever logged.
- Phase 1 has no sign-in, so `UserStore.localUser()` creates a placeholder lifter on first launch. Phase 2's Cognito replaces the *identity*, not the storage.
- `SetType` has no `failure` case: per `Mid lift thoughts.md`, failure is RPE 10 plus forced partials or a weight drop, and Strong's sticky failure status was a real annoyance.
- `Exercise.sourceSlug` is an identity claim — this row *is* that vendored-catalog entry — and is uniquely indexed so two rows can't both claim to be one. A program's own wording for a lift lives in `PlannedExercise.variant`, never in a second slug field. (There *was* a `matchedSlug` alongside it, holding what a name matcher guessed; it and the matcher are gone. The SQLite column survives unused because dropping one means rebuilding the table and a real device has to migrate forward.)

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

`-initialTab home|workout|plan|history|profile` picks the starting tab. It exists because simctl can install, launch, and screenshot but **cannot tap** — without it, only Home is reachable from the command line. Two more of the same kind: `-openPlanDay N` opens the planner's day editor, and `-restDemo <seconds>` starts a throwaway workout with two exercises, completes **every set of the first** through the real `completeSet` path, and leaves the rest timer running that long (`-restDemo 0` lands on the expired state). Finishing an exercise is deliberate: it hands "active" to the next lift, which is the state that used to fold the finished exercise shut with a live countdown inside it. Both are `#if DEBUG`. States behind a *second* tap — sheets, the timer's own ± buttons, the planner's Save/discard — still need a UI test target, which doesn't exist yet.

`-restDemo` writes a real in-progress workout, and it no-ops if one already exists, so clear it between runs:
```sh
sqlite3 "$DB" "delete from workoutSet; delete from workoutExercise; delete from workout;"
```
It also disables `RestNotifier` — the permission prompt would otherwise cover the thing being screenshotted, and nothing on the command line can dismiss it.

**Seeding data to see populated views:** write directly to the app's SQLite.
```sh
DB="$(xcrun simctl get_app_container "$D" com.rrochlin.LiftingCoach data)/Library/Application Support/LiftingCoach/db.sqlite"
```
The container UUID **changes on reinstall**, so re-resolve it every time. GRDB stores dates as `'YYYY-MM-DD HH:MM:SS.SSS'` in **UTC**, while the app normalizes days with the *local* calendar — so a local start-of-day is e.g. `07:00:00.000` at UTC-7. Get this wrong and rows silently don't match "today". `workoutSet.plannedFrom` is Swift-encoded JSON; generate it with the real encoder rather than hand-writing it (`LoadPrescription` encodes as `{"rpe":{"_0":8}}`).

Lesson worth keeping: running the app immediately found two bugs that compiled fine — weights rounding 157.5 lb to 158 lb, and logged RPE never displaying. **Screenshot new views; don't trust a green build.**

### Deploying to the phone
The iPhone 13 is usually connected. Two gotchas, both of which cost time before being written down:

1. **`devicectl` and `xcodebuild` use different device identifiers for the same phone.** `xcrun devicectl list devices` prints one (`2F0D37A5-…`); `xcodebuild`'s destination wants the hardware UDID (`00008110-…`), which it will list for you on a failed destination match.
2. **`project.yml` pins no `DEVELOPMENT_TEAM`** (deliberately — Xcode fills it from whoever's signed in). A command-line build therefore fails with "requires a development team" until you pass it. The team is the `OU` of the signing certificate: `security find-identity -v -p codesigning`, then `security find-certificate -c "<that name>" -p | openssl x509 -noout -subject`.

```sh
DEV=2F0D37A5-1A73-5D88-9E6A-61DFC7603A0A          # devicectl identifier
UDID=00008110-000C71260121401E                     # xcodebuild destination
DD=/tmp/lifting-coach-device
xcodebuild -project LiftingCoach.xcodeproj -scheme LiftingCoach \
  -destination "id=$UDID" -configuration Debug \
  DEVELOPMENT_TEAM=33G44VZ97Z -allowProvisioningUpdates \
  SYMROOT="$DD/Products" OBJROOT="$DD/Intermediates" SHARED_PRECOMPS_DIR="$DD/PCH" build

xcrun devicectl device uninstall app --device "$DEV" com.rrochlin.LiftingCoach   # wipes its data
xcrun devicectl device install app --device "$DEV" "$DD/Products/Debug-iphoneos/LiftingCoach.app"
xcrun devicectl device process launch --device "$DEV" com.rrochlin.LiftingCoach
```

**The launch will fail after a fresh uninstall** with "profile has not been explicitly trusted by the user" — uninstalling the last app from a developer identity removes the trust with it. Re-trusting is a tap on the phone (Settings → General → VPN & Device Management → the developer profile → Trust) and **nothing here can do it**; hand that step to the owner.

## Working conventions from this project
- The notes docs are living working files, not archives — once a design conversation converges on a direction, implement it directly in the relevant `.md` (or, going forward, the actual Swift code). Don't leave agreed decisions sitting only in chat.
- The repo owner is newer to Swift specifically (not to programming or architecture) — double-check type names against real Foundation/Swift APIs rather than assuming (past mistakes caught: `DateTime`→`Date`, `Dict`→`Dictionary`, `Uuid`→`UUID`, a custom `Unit`/`Set` type shadowing Swift's built-ins) and flag Swift-specific idioms proactively (structs can't inherit — only classes/protocols; `Hashable`/`Equatable` requirements for dictionary keys; `Measurement<UnitMass>` over raw numbers for anything weight-related, for consistent unit handling).

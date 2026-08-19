## #Workout
A workout refers to an instance of a user using the [[Workout Tracker]]. A workout could be in progress or completed. Workouts are an ordered collection of #WorkoutExercise and have definite attributes associated with them.
```swift
struct Workout {
	// double array for super sets
	var exercises: Array<Array<WorkoutExercise>>?
	var startTime: Date?
	var endTime: Date?
	var notes: String?
	var usernotes: String?
	// where this workout came from. nil = logged in this app; anything else
	// names the translation that produced it ("strong-csv"). See "Imports are
	// translated, never guessed" below.
	var source: String?
}
```

## #PlannedWorkout
A planned workout is created by the coach as a list of #PlannedSet's that will be executed in order to complete a workout. This will be used to populate the UI with a workout when the user actually wants to do one while also being able to fill in suggested weights etc.
```Swift
struct PlannedWorkout {
	// always use start of day
	var date: Date?
	var exercises: Array<Array<PlannedExercise>>?
	var notes: String?
}
```

## #Exercise
Exercises are catalog entries for specific lifts/activities (bench press, deadlift) — the reusable definition, not a specific instance of doing them. String names and id's can be used to index into workout history to look for historical trends.

`muscleGroup` is the one field every exercise has always carried. Everything else is catalog metadata that only a vendored-catalog entry (or one enriched from one — see "Exercise Catalog" below) carries; a manually-created exercise legitimately has all of it nil, and that's not a gap to fill in.
```swift
struct Exercise {
	var name: String
	var id: Int
	var muscleGroup: String

	var equipment: String?
	var primaryMuscles: Array<String>?
	var secondaryMuscles: Array<String>?
	var instructions: Array<String>?
	var level: String?      // beginner / intermediate / expert
	var category: String?   // strength / cardio / stretching / powerlifting / ...
	var mechanic: String?   // compound / isolation
	var force: String?      // push / pull / static
	// identity: this row IS that vendored-catalog entry. Unique when present —
	// lets a re-import upsert instead of duplicating rows.
	var sourceSlug: String?
	// this names a goal or muscle group, not one movement ("pick a triceps
	// exercise," "45 min LSS cardio") — see "Exercise Catalog" below. Achieved-
	// max tracking must never compare weights across an open-choice exercise.
	// Authored by whoever writes the program; never inferred from the name.
	var isOpenChoice: Bool
	// movements the program floated for an open slot ("overhead extension,"
	// "pushdown"). Suggestions, not a whitelist — the lifter picks what they
	// pick and the app never refuses one.
	var suggestions: Array<String>?
}
```

## #WorkoutExercise

The execution of an #Exercise within a specific #Workout — tracks the sets actually performed and any notes, distinct from the catalog definition above.
```swift
struct WorkoutExercise {
	var exercise: Exercise
	var sets: Array<WorkoutSet>?
	// the plan's own wording, carried over from PlannedExercise.variant so
	// history stays readable without the plan in hand
	var variant: String?
	var notes: String?
	var usernotes: String?
}
```

## #PlannedExercise
The planned counterpart to #WorkoutExercise — pairs an #Exercise with the #PlannedSet's prescribed for it within a #PlannedWorkout, so a plan can say which exercise a group of planned sets actually belongs to.
```swift
struct PlannedExercise {
	var exercise: Exercise
	var sets: Array<PlannedSet>?
	// the default effort target for every set of this exercise — "5x2 @ RPE 7" is
	// one instruction, written once here. Individual sets override via their own
	// effort field; consumers resolve set.effort ?? exercise.effort
	var effort: EffortTarget?
	// how this exercise is being done today, in the program's own words:
	// "Bench press — heavy (paused, comp grip)", "Bench volume — Spoto press"
	var variant: String?
	var notes: String?
}
```

## Variant vs. exercise
A program routinely prescribes the same lift twice in one session under different instructions — heavy paused bench, then back-off sets. Those are **one** #Exercise: they share a max, they share achieved-max history, and giving each its own catalog entry is exactly the duplication the program→catalog mapping exists to prevent.

They are **not** one instruction. `variant` carries the plan's own wording; `exercise` stays the canonical catalog identity underneath. Display resolves as `variant ?? exercise.name` (`displayName`), so a day prescribing both reads as two lines rather than as one exercise listed twice, while every percentage and every recorded max still resolves against the same lift.

`variant` is prescription, never identity. Nothing keys off it, nothing matches on it, and two exercises with different variants are still the same lift.

## Load and effort
Rationale in [[Core Tenets]] §2–§5. What implementers need:

**Two independent optional fields, never one enum.** `load` says what to put on the bar; `effort` says how hard it should feel. Either may be nil — a warmup usually has load and no effort, an accessory can be "3×10 @ RPE 8, pick your weight" with no load. Don't treat a nil as incomplete data or backfill it.

**Effort resolves set-first, then exercise.** #PlannedExercise carries the target; #PlannedSet may override it. Resolution is `set.effort ?? exercise.effort` — the same shape as `restTime`'s fallback chain.

**RPE is 1–10 in 0.5 increments.** Validate on that. Do not add an RIR property, computed or stored ([[Core Tenets]] §3).

**No consumer adjusts a prescription automatically** — not the tracker, not the planner. Modality (ceiling, target, to-failure, dual progression) is carried in `notes` and interpreted by the lifter ([[Core Tenets]] §1, §4).

## #Set
Sets compose a #WorkoutExercise, they detail how many reps, what weight, and how it went. A #PlannedSet is the prescription (load and effort, per above); a #WorkoutSet is what was actually logged.
```swift
import Foundation

enum SetType {
	case working
	case drop
	case warmup
}


struct WorkoutSet {
	var reps: Int?
	var weight: Measurement<UnitMass>?
	var complete: Bool?
	var type: SetType?
	var timeComplete: Date?
	// legacy — nothing writes this. Rest actually taken is NOT recorded; see
	// "Rest is prescribed, not measured" below. Kept only so history logged
	// before that decision isn't destroyed.
	var restTime: Int?
	// rest the lifter set for THIS set, overriding the prescription. Distinct
	// from restTime above (measured, legacy) and from plannedFrom.restTime
	// (what the program asked for). See "Rest is prescribed, not measured".
	var restOverride: Int?
	// the unit THIS set is read and entered in, overriding the exercise's
	// preference and the app default. See "Units are a reading preference".
	// A field of its own, not derived from weight.unit: an empty set has no
	// weight yet and still needs to say what unit it's being entered in.
	var unit: WeightUnit?
	// work measured in time and distance rather than reps: a plank, a bike
	// interval, a walk. Nothing to do with the two rest fields above — those
	// are the gap BETWEEN sets, this is the set itself. A set carrying a
	// duration usually has no reps and no weight, and that is a complete
	// record, not a half-filled one.
	var duration: Measurement<UnitDuration>?
	var distance: Measurement<UnitLength>?
	// achieved effort as the lifter rated it, per set — never defaulted from the
	// prescription. Same scale as #RPE.
	var rpe: Float?
	var notes: String?
	var usernotes: String?
	// what this set was prescribed as, if any — lets planned vs actual be reconciled without needing user context wherever a WorkoutSet is read
	var plannedFrom: PlannedSet?
}
```

## #PlannedSet 
```Swift
// What to put on the bar. Resolved to an absolute weight when the plan becomes a
// live Workout; a percentage that can't be resolved stays unresolved rather than
// guessing a number.
enum LoadPrescription {
	case absolute(Measurement<UnitMass>)
	// The MaxReference is not optional: "80%" is unresolvable until you know 80%
	// of which number. See #Maxes.
	case percentOf(Double, of: MaxReference)
}

// How hard the set should feel. RPE 1-10 in 0.5 increments; see #RPE for anchors.
struct EffortTarget {
	var rpe: Float
}

struct PlannedSet {
	var reps: Int?
	var type: SetType?
	var load: LoadPrescription?
	// nil means "use the containing PlannedExercise's effort" — this field is an
	// override for the odd set out (a top single, a back-off), not the normal
	// place to put a target
	var effort: EffortTarget?
	// seconds; nil falls back to the containing WorkoutBlock's defaultRestTimes for this SetType, then an app-level default — most sets shouldn't need this configured explicitly
	var restTime: Int?
	// carries programming intent that has no structural home: "work up, stop at 9",
	// "last set AMRAP", tempo, pauses
	var notes: String?
}

```

## Set completion is stamped; a set is still an instant, not an interval
#WorkoutSet `timeComplete` records when a set was checked off, to the millisecond, and is kept precise on purpose: it's the anchor anything else on the same clock — a heart rate series, sleep, HRV — would be lined up against later.

**It is the tap, not the last rep.** The lifter racks the bar, breathes, picks the phone up and hits the checkbox. That lag never cancels out, and it's the same bias that got measured rest deleted (below). Anything reading these as physiology carries the caveat; nothing presents one as the moment work stopped.

**There is no recorded set start**, so "working rather than resting" is not answerable from the log — only *inferrable* from consecutive completions, and that inference belongs to whatever analyses the data, not to storage. Recording a real start was considered and deliberately not built: the honest ways to get one are a per-set gesture mid-workout or an event written when the rest timer ends, and neither earns its cost until something consumes the data. Revisit when HealthKit correlation is actually being built, not before.

**Two honest nils**: a set that isn't complete, and the whole imported history — the Strong export carries no per-set times, so 14,520 sets have none and never will. Analysis has to tolerate that hole rather than fill it.

## Rest is prescribed, not measured
Rest owed resolves in one chain: #WorkoutSet `restOverride`, then #PlannedSet `restTime`, then the #WorkoutBlock's `defaultRestTimes` for that #SetType, then an app default. `WorkoutSession.restTarget(afterSetWith:)` walks it; `prescribedRest(afterSetWith:)` walks the same chain minus the override, which is what "back to prescribed" reverts to.

`restOverride` is the lifter's own rest for one set, tuned in the tracker. It's a separate field from `plannedFrom.restTime` on purpose: writing into the snapshot would make a lifter's 3:30 read back later as though the program had prescribed it, and planned vs. actual are never silently substituted ([[Core Tenets]] §6). It outranks everything below it — the person doing the lift is the most specific authority on how long they're resting (§1) — and it's per set, because back-off sets after a heavy triple don't want the triple's three minutes.

Rest is also authorable per set in the planner (#PlannedSet `restTime` was always per set; only the UI wrote it uniformly). The exercise-level control still writes every set at once, since "three minutes on squats" is usually one instruction.

Rest *taken* is deliberately not recorded. It used to be, derived as the gap between two completion timestamps, and that number is wrong in a way that doesn't average out: it's the rest plus however long it took to pick the phone up and check a box, so it always reads long. A measurement biased one direction every time is worse than no measurement, because it still looks like data — and #Ideas' whole reason for wanting logged history is analysis. `WorkoutSet.restTime` survives as a legacy column so rows written before this decision aren't destroyed; nothing writes it.

If rest taken ever needs to be real, it has to come from the timer itself (started, adjusted, and ended by the lifter), not from inference — and that's a decision to make deliberately, not to fall into.

## #RPE
A single scale used for both prescribed and achieved effort. Exertion, **not** reps in reserve — see [[Core Tenets]] §3 before changing anything here.

Valid range 1–10 in 0.5 increments. Anchored only from 6 up, because that's the programming band:

| RPE | Meaning |
| --- | --- |
| 10 | Failure, or no chance of another rep |
| 9 | All-out effort |
| 8 | Exertion |
| 7 | Some effort |
| 6 | Easy |
| <6 | No descriptor — warmups, deload, easy conditioning |

Values below 6 are valid and storable; the UI should show them as a bare number rather than inventing a label.

## #WorkoutBlock
A training block: a bounded span of time (e.g. a 6-week strength cycle) made up of scheduled #Workout 's, plus notes on the block's objectives and a running journal.
```swift
struct WorkoutBlock {
	// keyed by the start of each calendar day (always normalize to Calendar.startOfDay before using as a key). Value is an array to support multiple workouts on the same day (e.g. AM/PM)
	var workouts: Dictionary<Date, Array<Workout>>?
	// program holds all of the planned activities
	var program: Dictionary<Date, Array<PlannedWorkout>>?
	var startDate: Date?
	// planned end — a target, not authoritative. Blocks routinely run past this (slipped schedules, unlogged deload weeks), so nothing should treat crossing endDate as "the block is over." See WorkoutPlan for how "current block" is actually derived.
	var endDate: Date?
	var notes: String?
	var journal: String?
	// fallback rest time (seconds) per SetType, used when a PlannedSet doesn't specify its own
	var defaultRestTimes: Dictionary<SetType, Int>?
}
```

## Moving a block, and why the app asks first
A block's `program` is keyed by absolute date, materialized from a date-free
program file onto a start date (`ProgramLoader`). That's the right storage — a
programmed day is a day, and everything from the tracker's week view to Home's
"today" reads it as one — but it means a block created against the wrong start
date can't be corrected by editing one field. The days are already somewhere.

So changing a start date is two different edits wearing one name, and the block
editor makes the lifter say which:

- **Rescheduling** (`WorkoutBlock.rescheduled(to:calendar:)`) moves every
  programmed day, every `PlannedWorkout.date`, and the planned end by the same
  number of calendar days. The program's shape — which lifts fall on which day
  of which week — is exactly preserved, which is the same contract
  `ProgramLoader` has when it lands a file onto a start date. This is what
  "I'm actually five weeks into this" means: week 6's programming has to
  arrive *now*, not week 1's under a new label.
- **Restating the start** leaves the days where they are and changes only the
  block's own `startDate`. Which week each day falls in changes, because weeks
  are counted from the anchor. This is the correction for a date recorded
  wrong.

Neither is inferable from the edit itself, so neither is the default the app
picks quietly (Core Tenets §1). The shift is shown as a count of days and days
moved before it lands, and it never touches a prescription or a logged workout
— rescheduling moves *when*, never *what*.

Shifted days are moved by calendar day rather than by elapsed seconds, so a
block moved across a daylight-saving boundary keeps landing on the start of a
day.


## #WorkoutPlan
The umbrella for all of a #User's programming — a sequence of #WorkoutBlock 's over time. Starting a new training block means appending a new #WorkoutBlock here, not creating a new plan.
```swift
struct WorkoutPlan {
	var blocks: Array<WorkoutBlock>?
	// currentBlock and nextBlock are derived, not stored, so there's no second copy of either fact to go stale:
	// - currentBlock = sort blocks by startDate, take the last one with startDate <= today. This deliberately ignores endDate — a block whose planned end has passed (slipped schedule, an unlogged deload week) stays current until the *next* block's startDate actually arrives, so nothing disappears on the block's last day.
	// - nextBlock = the block immediately after currentBlock in that same sorted order, whether or not it's started yet — surfaced during deload so the user can preview/review what they're training toward next.
}
```

## #Maxes
"1RM" is three distinct data points per lift, and they are never interchangeable ([[Core Tenets]] §6):

```swift
// which max a percentage prescription resolves against
enum MaxReference {
	// actually lifted, verified, date-stamped — the only one that is a fact
	case achieved
	// what the program is written against; aspirational by construction.
	// A plan built on goal maxes is intentional, not an error to correct.
	case goal
	// estimated from logged work; derived, never entered by hand, recomputed as
	// history accrues. Not persisted as a stored value — see note below.
	case theoretical
}

struct AchievedMax {
	var weight: Measurement<UnitMass>
	// when it was lifted — an achieved max is an event, not a setting
	var date: Date
	var notes: String?
}

struct GoalMax {
	var weight: Measurement<UnitMass>
	// when the goal was set, so a stale goal is visible as stale
	var dateSet: Date?
}
```

Implementation notes:
- `.achieved` resolves to the **most recent** achieved max for the lift; keep the full history rather than overwriting, since the progression itself is data.
- `.theoretical` is computed on demand from logged sets, never stored — persisting it would create a second copy that goes stale, same reasoning as `currentBlock`. Until the estimation model exists (see [[Ideas]] on the flaws in standard formulas), a `.theoretical` reference is simply unresolvable and the set's weight stays blank ([[Core Tenets]] §10).
- Resolving a percentage against a max the user doesn't have recorded is not an error — the prescription displays as-is ("80% goal") with no weight.

## #User
A user is the target of a #WorkoutPlan. The plan is designed for the user, and the user also has metrics tracked related to their performance.
```swift
struct User {
	var workoutPlan: WorkoutPlan?
	// keyed by Exercise.id. Achieved maxes append; goal maxes replace.
	var achievedMaxes: Dictionary<Int, Array<AchievedMax>>?
	var goalMaxes: Dictionary<Int, GoalMax>?
	// always use start of day, same as WorkoutBlock's dictionaries
	var bodyWeight: Dictionary<Date, Measurement<UnitMass>>?
	var preferredUnit: WeightUnit  // lb | kg — a reading preference, see below
	// per-lift unit preferences, keyed by Exercise.id, same shape as goalMaxes.
	// Sticky across sessions: a rack of kg dumbbells stays kg for that lift.
	var exerciseUnits: Dictionary<Int, WeightUnit>?
	var email: String
	var uuid: UUID
	var name: String
}
```

## Units are a reading preference, not a storage format

Weights are stored in whatever unit they were entered in — `Measurement<UnitMass>` persists as value plus unit symbol, never normalized. `User.preferredUnit` decides what a lifter *reads*, and every weight the app displays is converted on the way to the screen.

The two rules that follow from that split:

- **Switching units rewrites nothing.** A set logged at 225 lb is still a 225 lb row after the lifter switches to kg; it simply reads as 102.1 kg. Converting the tables instead would round every historical row and make a display choice destructive.
- **A conversion rounds to a tenth; an unconverted weight is left exactly alone.** 157.5 lb read in pounds is what the lifter typed, and rounding it would be the app editing their log. A converted weight's extra decimals are conversion noise — a tenth of a kilo is more than ten times finer than the smallest plate on any bar.

### The unit chain

A unit resolves most-specific-first, the same shape rest already resolves in:

**`WorkoutSet.unit` → `User.exerciseUnits[exercise.id]` → `User.preferredUnit`**

Three levels because a real gym has three answers. The app default is what you
read everywhere. The per-lift preference is sticky and exists because the
dumbbell rack is marked in kg and will still be next Tuesday — re-setting it
every session is the friction it removes. The per-set override is for the one
set done on the other rack.

Every level is *authored by the lifter*, so the most specific one wins outright
([[Core Tenets]] §1) — the app never averages a preference against a program.

The rules above hold at every level. **Switching any of them rewrites nothing:**
a set logged at 100 lb pinned to kg reads 45.4 kg, the same iron. It is never
reinterpreted as 100 kg — that would be a correction, and this is a display
choice.

There's one deliberate asymmetry, in the planner. An **authored** absolute load keeps the unit it was written in (the load mode menu is where lb/kg is chosen for a prescription — that's authorship, and the plan means what it says). A **derived** weight — 72% of a 495 lb goal — reads in the lifter's unit like everything else.

`WeightUnit` is a two-case enum rather than all of `UnitMass`: grams and stones are real units and neither is a plausible answer to "what do you load your bar in." Its raw values are the same symbols weights are stored under, so a preference and a stored weight's unit column speak the same language.

## Exercise stats are derived and rebuilt, never incremented

Per-lift history — how many completed workouts contain a lift, when it was last
done, the heaviest working set — is stored in an `exerciseStats` table, and the
distinction that makes that safe is worth stating plainly, because the obvious
reading of "stored aggregate" is the wrong one.

**Nothing increments it.** `ExerciseStatsStore.rebuild(for:)` recomputes every
row from the log in one statement and is the only writer. It runs on the few
events that change history: finishing a workout, deleting one, finishing an
import.

The alternative — a counter adjusted at write time — has to be adjusted
correctly by *every* path that touches the log: finishing a workout (which
deletes its incomplete sets), discarding one, deleting a set, editing history,
importing. Miss one and the number is wrong permanently, with nothing able to
detect it. A recomputed table can only ever be *stale*; it cannot disagree with
the log, because the log is what it's computed from, and dropping it is always a
valid repair. There's a test asserting rebuild is idempotent and agrees with the
equivalent live query, and it should stay.

Why store it at all, when the live query measures ~3 ms over five years of real
history? Not latency. Because a CSV import lands a whole training career in one
transaction and wants stats to exist immediately rather than be recomputed by
whoever opens a picker first — and because the fatigue and theoretical-max
models in [[Ideas]] are more aggregates that will want a home. One rebuilt table
is where those go.

What it's *for*, concretely: ordering the exercise picker by what the lifter
actually uses (twenty real lifts above eight hundred they'll never pick), and
proposing a starting weight for an unplanned set — see `SetSuggestion`, which is
a proposal the lifter edits, never a prescription ([[Core Tenets]] §1), and only
ever fills a field that was empty because nothing was prescribed there.

## Three editing models, and when each saves
The app edits workouts in three places, and the difference between them is *when a write happens*, not what the screens look like.

**`WorkoutSession`** is the tracker, and it saves after **every** mutation. A workout is a live thing; a phone that locks in a gym bag and gets killed by the OS has to come back with every logged set intact, so there is no such thing as an unsaved rep here.

**`PlannedWorkoutDraft`** is the planner, and it saves on demand. Programming is deliberate authoring — a half-typed percentage should not become the plan — so edits accumulate against an `original` and land on an explicit Save, with a confirmation on the way out.

**`LoggedWorkoutDraft`** corrects a workout already in the log, and takes the planner's shape rather than the tracker's. There is nothing to recover: the session is over. Fixing a set logged in March is authoring, and a half-typed weight shouldn't overwrite five years of history on the way to being finished.

All three compare **structurally** rather than setting a dirty flag, so typing a value and typing it back leaves nothing to save and warns about nothing on the way out.

**Correcting history reaches what was lifted, and nothing else.** `Workout.source` and each set's `plannedFrom` stay untouched by an edit — the first is a fact about where the row came from, the second is what was *asked for*, and an edit that could reach either would let a correction rewrite provenance or make adherence lie. A contradiction (a workout that ends before it starts) is **reported and blocks the save**, never resolved by moving the other end of the range: that would silently change a number nobody touched.

**Editing does not replay achieved maxes.** Correcting a weight downward leaves the #AchievedMax event recorded at the time, because that table is append-only event history rather than something derived. `exerciseStats` *is* rebuilt on save, because rebuilding is that table's only write path. Making maxes derived instead is an open decision — see `notes/Feedback.md`.

## Imports are translated, never guessed
An external log — a Strong export, someone else's app, a spreadsheet — has the same three problems every time: its workouts belong to no #WorkoutBlock, its exercise names don't match the catalog, and some of its columns have nowhere to land. The answer is the one "Programs name exercises, they don't describe them" already settled, applied to imports.

**Three stages, and only the middle one is allowed to think.** A deterministic, catalog-blind parser turns the export into a normalized staging file. A person or an agent then decides, *once*, what each of the source's exercise names actually is, and that decision is committed to the repo as a mapping artifact. A strict loader reads only that mapping and aborts on any name it doesn't cover.

Measured, on the owner's own five-year Strong export: matching its 149 exercise names against the vendored catalog by string similarity resolves **31**. The top candidate for "Squat (Barbell)" is *Front Barbell Squat To A Bench*. That is why the middle stage is a person and not a function, and why nothing in the app's own code reads a name and guesses — see `scripts/README.md` and `scripts/data/strong_exercise_map.json`.

The mapping records one of three authored outcomes per name. **slug**: this name *is* that catalog entry. **create**: a real specific lift the vendored catalog doesn't have ("Belt Squat"), minted the way #ProgramLoader mints open slots. **openChoice**: the name states a goal, not a movement — five years of "Triceps Extension" across a 50–160 lb range is demonstrably not one lift, and marking it open is what stops `AchievedMaxUpdate` recording a max that means nothing. Plus an optional **variant**, for where the source's wording is prescription rather than identity: a Pendlay row and a bent-over row share a max, so they share an #Exercise and differ by variant.

**`Workout.source` is provenance, not a category.** It earns its place twice: a reload replaces exactly what a given source wrote instead of doubling the log, and history can say a session was imported rather than letting five years of another app read as though it were tracked here. `achievedMax` carries the same tag, and needs it more — maxes are append-only events, so a second import run would announce the same records again with nothing able to tell the copies apart.

**Imported workouts have no block and no prescription.** `blockId` and `plannedFrom` are both nil, which is honest: there was no plan. Block adherence joins on `blockId`, so imported history can't distort it.

## Exercise Catalog
Resolved: backed by a vendored snapshot of `yuhonas/free-exercise-db` (public domain, ~870 exercises — equipment, muscle groups, instructions, category). See `notes/Workout App/workout_assets_overview.md` for the license survey this came out of, and `LiftingCoachModel/Sources/LiftingCoachPersistence/Resources/FreeExerciseDB.LICENSE.txt` for exact provenance. Vendored, not fetched live — a shipped app depending on a third-party GitHub URL for its own catalog is an availability/integrity risk not worth taking for data this static.

**Images were deliberately not vendored.** The full image set is ~90-100MB of JPEGs; no screen in the app displays an exercise photo yet, so that cost isn't justified today. Worth revisiting once something actually needs them — the upstream repo still has them, keyed by the same slug this app already stores as `sourceSlug`.

### Programs name exercises, they don't describe them

**A program says which exercise it means. Nothing in the app works it out from the name.** There are exactly two ways to program a slot:

1. **Directly** — the plan's own wording plus the catalog entry it refers to. "Bench press — heavy (paused, comp grip)" *is* `Barbell_Bench_Press_-_Medium_Grip`; the wording lives in `variant`, the identity in the exercise itself.
2. **As an open choice** — the plan names a goal or a muscle group and leaves the movement to the lifter, carrying only the fields that limit or suggest: a muscle group, and whatever movements it floated (`suggestions`).

There is deliberately no third case, and in particular **no code that reads an exercise's name and decides what it probably is.** An earlier version had one — a keyword matcher scoring a program's wording against the canonical catalog. It was removed. Two reasons, and the second is the real one:

- It could be wrong in ways nothing downstream could detect. A "heavy" deadlift matched "Heavy Bag Thrust" on the word "heavy" alone. Gating on movement words fixed that case and not the class of problem.
- **It solved a problem that shouldn't exist.** A program is authored, not discovered. Whoever writes it knows whether they mean one specific lift or the lifter's choice, and a workout plan only ever exists in this app or its database — so that knowledge can simply be recorded when the plan is written. Inferring it later is re-deriving something that was never unknown.

The consequence for importing anything external (the owner's original spreadsheet, say): the translation happens **once, by hand, into the app's language**, and the result is what ships. See `Resources/Block1.json` and `ProgramLoader` — the loader is transcription, and a program naming an exercise the catalog doesn't have fails to load rather than approximating.

**An open slot is a real prescription, not a gap.** "Triceps (overhead ext / pushdown)," "Core (ab wheel / hanging leg raise)," "45 min LSS cardio" — a coach specifying a goal and leaving the implementation up to the lifter is normal, deliberate programming, and a walk, a bike, and a stair climber are all correct answers to the last one.

`Exercise.isOpenChoice` is load-bearing, not cosmetic: `AchievedMaxUpdate` refuses to record a max for an open-choice exercise, because a heavier weight logged under it than last time doesn't mean progress on the same lift — it might not be the same lift at all. Which is exactly why it's authored rather than guessed: an inferred flag would let a correctly-programmed lift with an unusual name silently stop tracking maxes.

**"More advanced searching down the line" is about the exercise picker**, not about program loading. It has nothing to do with how a program names its exercises, which is now settled.

That searching is now built — `ExerciseSearch` — and the boundary between it and the deleted matcher is worth stating precisely, because on the surface both "read a name and find an exercise".

**The difference is who decides.** The matcher's output *became* the answer: it wrote an identity into the data, and a wrong guess mislabeled logged history permanently with nobody in a position to notice. Search's output is a **ranked list of candidates a lifter then taps**. A wrong guess puts the right lift second. One is inference standing in for a decision that was always available to be recorded; the other is helping a person find something they are actively looking for.

The practical test: **anything that consumes search output without a person choosing is the forbidden thing wearing a new name.** Program loading must never call it.

The guess in the sentence this replaced — that better search would mean embeddings or an LLM — was measured and is wrong, which is worth keeping as a caution about answering this kind of question from intuition. Both of Apple's on-device embedding models are *worse* than string matching on this catalog: they encode topical relatedness rather than synonymy, so every gym word sits near every other one (`squat` is nearer `deadlift` than any true synonym pair), and the domain's actual vocabulary gaps — *pec deck* meaning *butterfly* — are exactly what a general English model doesn't know. What works is ordinary information retrieval (tokens, rare-word weighting, stemming, a fuzzy tier) plus a small **authored** alias table for the jargon, which is the same "record the judgment once" pattern as the rest of this section.

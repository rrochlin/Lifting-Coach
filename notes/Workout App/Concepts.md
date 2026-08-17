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
	// provenance, not identity: the catalog entry CatalogMatcher best-effort
	// matched this exercise against to borrow its metadata. NOT unique — several
	// program exercises can and do legitimately match the same canonical entry.
	var matchedSlug: String?
	// this names a goal or muscle group, not one movement ("pick a triceps
	// exercise," "45 min LSS cardio") — see "Exercise Catalog" below. Achieved-
	// max tracking must never compare weights across an open-choice exercise.
	var isOpenChoice: Bool
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

## Rest is prescribed, not measured
Rest exists in the model in exactly one place: #PlannedSet `restTime`, falling back to the #WorkoutBlock's `defaultRestTimes` for that #SetType, then an app default. That's rest *owed*.

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
	var email: String
	var uuid: UUID
	var name: String
}
```

## Exercise Catalog
Resolved: backed by a vendored snapshot of `yuhonas/free-exercise-db` (public domain, ~870 exercises — equipment, muscle groups, instructions, category). See `notes/Workout App/workout_assets_overview.md` for the license survey this came out of, and `LiftingCoachModel/Sources/LiftingCoachPersistence/Resources/FreeExerciseDB.LICENSE.txt` for exact provenance. Vendored, not fetched live — a shipped app depending on a third-party GitHub URL for its own catalog is an availability/integrity risk not worth taking for data this static.

**Images were deliberately not vendored.** The full image set is ~90-100MB of JPEGs; no screen in the app displays an exercise photo yet, so that cost isn't justified today. Worth revisiting once something actually needs them — the upstream repo still has them, keyed by the same slug this app already stores as `sourceSlug`.

**Names don't line up 1:1 with real programming.** A spreadsheet-authored program names exercises the way a lifter thinks about them ("Bench press — heavy (paused, comp grip)"), not the way a canonical database names them ("Barbell Bench Press - Medium Grip"). `CatalogMatcher` does one-time, best-effort keyword matching to enrich a manually-named exercise with the canonical entry's metadata **without changing its name or id** — see its doc comment for exactly how, and for the real false positives (a "heavy" deadlift nearly matching "Heavy Bag Thrust") that shaped the current movement-word-gated approach.

**Some exercises aren't unmatched because the matcher failed — they don't name a single movement in the first place.** "Triceps (overhead ext / pushdown)," "Core (ab wheel / hanging leg raise)": a coach specifying a goal or a muscle group and leaving the implementation up to the lifter is normal, deliberate programming — no different from "45 min LSS cardio," where a walk, a bike, and a stair climber are all correct answers. This is `Exercise.isOpenChoice`, not a matching gap to eventually close. `CatalogImporter` sets it as a heuristic whenever `CatalogMatcher` finds nothing sharing even one movement word — a decent proxy, not a certainty, but the failure mode (a missed enrichment) is the safe direction to be wrong in.

This flag is load-bearing, not cosmetic: `AchievedMaxUpdate` refuses to record a max for an open-choice exercise, because a heavier weight logged under it than last time doesn't mean progress on the same lift — it might not be the same lift at all.

**"More advanced searching down the line" belongs to the matcher's genuine misses**, not to open-choice exercises — those are correctly unmatched forever, by design. If the keyword matcher's real false negatives (a specific movement it just didn't recognize) ever become worth fixing, that's embeddings or an LLM call, not more hand-tuned heuristics.

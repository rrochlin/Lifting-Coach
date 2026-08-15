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
```swift
struct Exercise {
	var name: String
	var id: Int
	var muscleGroup: String
}
```

## #WorkoutExercise

The execution of an #Exercise within a specific #Workout — tracks the sets actually performed and any notes, distinct from the catalog definition above.
```swift
struct WorkoutExercise {
	var exercise: Exercise
	var sets: Array<Array<WorkoutSet>>?
	var notes: String?
	var usernotes: String?
}
```

## #PlannedExercise
The planned counterpart to #WorkoutExercise — pairs an #Exercise with the #PlannedSet's prescribed for it within a #PlannedWorkout, so a plan can say which exercise a group of planned sets actually belongs to.
```swift
struct PlannedExercise {
	var exercise: Exercise
	var sets: Array<Array<PlannedSet>>?
	var notes: String?
}
```

## #Set
Sets compose a #WorkoutExercise, they detail how many reps, what weight, and how it went. A #PlannedSet is the prescription (what should be done, possibly as %1RM or RPE rather than a fixed weight); a #WorkoutSet is what was actually logged.
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
	var restTime: Int?
	var RPE: Float?
	var notes: String?
	var usernotes: String?
	// what this set was prescribed as, if any — lets planned vs actual be reconciled without needing user context wherever a WorkoutSet is read
	var plannedFrom: PlannedSet?
}
```

## #PlannedSet 
```Swift
// how a planned set's intensity is defined — resolved to an absolute weight when the plan is turned into a live Workout
enum LoadPrescription {
	case absolute(Measurement<UnitMass>)
	case percentOf1RM(Double)
	case rpe(Float)
}

struct PlannedSet {
	var reps: Int?
	var type: SetType?
	var load: LoadPrescription?
	// seconds; nil falls back to the containing WorkoutBlock's defaultRestTimes for this SetType, then an app-level default — most sets shouldn't need this configured explicitly
	var restTime: Int?
	var notes: String?
}

```

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

## #User
A user is the target of a #WorkoutPlan. The plan is designed for the user, and the user also has metrics tracked related to their performance.
```swift
struct User {
	var workoutPlan: WorkoutPlan?
	// keyed by Exercise.id
	var maxLifts: Dictionary<Int, Measurement<UnitMass>>?
	// always use start of day, same as WorkoutBlock's dictionaries
	var bodyWeight: Dictionary<Date, Measurement<UnitMass>>?
	var email: String
	var uuid: UUID
	var name: String
}
```

## TODO — Exercise Catalog
Still need a real exercise catalog backing #Exercise (assets, muscle group diagrams, equipment type, etc.). Strong/Heavy appear to draw from a similar free/shared asset set — worth using as a placeholder source while the app stays internal, with a plan to swap in properly licensed assets before any public release.

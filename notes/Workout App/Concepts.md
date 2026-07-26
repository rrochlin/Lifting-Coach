## #Workout
A workout refers to an instance of a user using the [[Workout Tracker]]. A workout could be in progress or completed. Workouts are an ordered collection of #Exercise and have definite attributes associated with them.
```swift
struct Workout {
	// double array for super sets
	var lifts: Array<Array<Exercise>>
	var startTime: Date
	var endTime: Date
}
```

## #Exercise 
Exercises are specific lifts/activities that make up a workout. Exercises have string names and id's that can be used to index into the workout history to look for historical trends. 
```swift
struct Exercise {
	var name: String
	var id: Int
	var sets: Array<Array<WorkoutSet>>
	var notes: String?
	var usernotes: String?
}
```


## #Set
Sets compose an exercise, they detail how many reps, what weight,
```swift
import Foundation

enum SetType {
	case working
	case drop
	case superset
	case warmup
}

struct WorkoutSet {
	var reps: Int
	var weight: Measurement<UnitMass>
	var complete: Bool
	var type: SetType
	var timeComplete: Date
	var restTime: Int
}
```
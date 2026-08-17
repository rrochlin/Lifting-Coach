import Foundation

/// The execution of an `Exercise` within a specific `Workout` — the sets
/// actually performed, distinct from the catalog definition.
public struct WorkoutExercise: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var exercise: Exercise
    public var sets: [WorkoutSet]?
    public var notes: String?
    public var usernotes: String?

    public init(
        id: UUID = UUID(),
        exercise: Exercise,
        sets: [WorkoutSet]? = nil,
        notes: String? = nil,
        usernotes: String? = nil
    ) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
        self.notes = notes
        self.usernotes = usernotes
    }
}

/// The planned counterpart to `WorkoutExercise` — pairs an `Exercise` with the
/// `PlannedSet`s prescribed for it within a `PlannedWorkout`.
public struct PlannedExercise: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var exercise: Exercise
    public var sets: [PlannedSet]?
    /// The default effort target for every set of this exercise — "5×2 @ RPE 7"
    /// is one instruction, written once here. Individual sets override via their
    /// own `effort`; consumers resolve `set.effort ?? exercise.effort`.
    public var effort: EffortTarget?
    public var notes: String?

    public init(
        id: UUID = UUID(),
        exercise: Exercise,
        sets: [PlannedSet]? = nil,
        effort: EffortTarget? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
        self.effort = effort
        self.notes = notes
    }

    /// The effort target in force for a given set of this exercise.
    public func resolvedEffort(for set: PlannedSet) -> EffortTarget? {
        set.effort ?? effort
    }
}

/// An instance of the user working out — in progress or completed. An ordered
/// collection of `WorkoutExercise`.
///
/// `exercises` is nested one level: the outer array is execution order, and each
/// inner array is a superset group performed together. A normal (non-superset)
/// exercise is a group of one.
public struct Workout: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var exercises: [[WorkoutExercise]]?
    public var startTime: Date?
    public var endTime: Date?
    public var notes: String?
    public var usernotes: String?

    public init(
        id: UUID = UUID(),
        exercises: [[WorkoutExercise]]? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        notes: String? = nil,
        usernotes: String? = nil
    ) {
        self.id = id
        self.exercises = exercises
        self.startTime = startTime
        self.endTime = endTime
        self.notes = notes
        self.usernotes = usernotes
    }

    /// A workout that has been started but not ended.
    public var isInProgress: Bool {
        startTime != nil && endTime == nil
    }

    /// Every logged set, flattened across superset groups and exercises.
    public var allSets: [WorkoutSet] {
        (exercises ?? []).flatMap { $0 }.flatMap { $0.sets ?? [] }
    }
}

/// A workout authored ahead of time, used to populate the tracker UI with
/// prescribed sets and suggested weights when the user starts training.
///
/// `exercises` nests the same way as `Workout.exercises`.
public struct PlannedWorkout: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Always normalized to the start of the day.
    public var date: Date?
    public var exercises: [[PlannedExercise]]?
    public var notes: String?
    /// When the lifter deliberately skipped this programmed day. Persisted
    /// rather than a UI-only dismiss — a skip is a decision, and it should stay
    /// visible in history the same way a completed workout does (Core Tenets
    /// §10: honest empty states, not silently hidden ones).
    public var skippedAt: Date?

    public init(
        id: UUID = UUID(),
        date: Date? = nil,
        exercises: [[PlannedExercise]]? = nil,
        notes: String? = nil,
        skippedAt: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.exercises = exercises
        self.notes = notes
        self.skippedAt = skippedAt
    }

    /// Every prescribed set, flattened across superset groups and exercises.
    public var allSets: [PlannedSet] {
        (exercises ?? []).flatMap { $0 }.flatMap { $0.sets ?? [] }
    }
}

import Foundation

/// The execution of an `Exercise` within a specific `Workout` — the sets
/// actually performed, distinct from the catalog definition.
public struct WorkoutExercise: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var exercise: Exercise
    public var sets: [WorkoutSet]?
    /// How this exercise was done, when that differs from the catalog lift —
    /// carried over from the prescription. See `PlannedExercise.variant`.
    public var variant: String?
    public var notes: String?
    public var usernotes: String?

    public init(
        id: UUID = UUID(),
        exercise: Exercise,
        sets: [WorkoutSet]? = nil,
        variant: String? = nil,
        notes: String? = nil,
        usernotes: String? = nil
    ) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
        self.variant = variant
        self.notes = notes
        self.usernotes = usernotes
    }

    /// What to show as this exercise's name: the plan's own wording where it
    /// has some, otherwise the catalog lift.
    ///
    /// The plan's wording wins because it's the more specific instruction —
    /// "Bench — back-off (paused)" tells the lifter what to do; "Barbell Bench
    /// Press - Medium Grip" is the identity that lets it share a max with the
    /// heavy paused sets earlier in the same session.
    public var displayName: String {
        guard let variant, !variant.isEmpty else { return exercise.name }
        return variant
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
    /// The plan's own name for this exercise, when it differs from the catalog
    /// lift: "Bench press — heavy (paused, comp grip)", "Bench volume — Spoto
    /// press (1\" off chest)".
    ///
    /// A prescription, not an identity. Heavy paused bench and Spoto bench are
    /// the *same lift* — they share a max, they share history, and splitting
    /// them into separate catalog entries is exactly what the program→catalog
    /// mapping exists to stop. But they are not the same *instruction*, and a
    /// day prescribing both would otherwise render as one exercise listed
    /// twice. That's what this carries, and why it lives on the plan rather
    /// than on `Exercise`.
    ///
    /// It's what `displayName` shows; `exercise.name` is still the catalog
    /// lift underneath, and screens with room for both show both.
    public var variant: String?
    public var notes: String?

    public init(
        id: UUID = UUID(),
        exercise: Exercise,
        sets: [PlannedSet]? = nil,
        effort: EffortTarget? = nil,
        variant: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
        self.effort = effort
        self.variant = variant
        self.notes = notes
    }

    /// What to show as this exercise's name: the plan's own wording where it
    /// has some, otherwise the catalog lift.
    ///
    /// The plan's wording wins because it's the more specific instruction —
    /// "Bench — back-off (paused)" tells the lifter what to do; "Barbell Bench
    /// Press - Medium Grip" is the identity that lets it share a max with the
    /// heavy paused sets earlier in the same session.
    public var displayName: String {
        guard let variant, !variant.isEmpty else { return exercise.name }
        return variant
    }

    /// The effort target in force for a given set of this exercise.
    public func resolvedEffort(for set: PlannedSet) -> EffortTarget? {
        set.effort ?? effort
    }

    /// Consecutive sets that share a prescription, collapsed into runs — the
    /// "5×2" a program is written in.
    ///
    /// Consecutive rather than global: "3×5 then 1×3" and "5, 3, 5" are
    /// different prescriptions, and collapsing by value alone would render them
    /// identically. An exercise whose sets are uniform (the common case)
    /// collapses to exactly one group, which is what lets a day's overview fit
    /// one line per exercise.
    public var setGroups: [SetGroup] {
        var groups: [SetGroup] = []
        for set in sets ?? [] {
            let effort = resolvedEffort(for: set)
            if var last = groups.last,
               last.reps == set.reps,
               last.load == set.load,
               last.effort == effort,
               last.type == set.type {
                last.count += 1
                groups[groups.count - 1] = last
            } else {
                groups.append(
                    SetGroup(
                        count: 1,
                        reps: set.reps,
                        load: set.load,
                        // Resolved, not the set's own: two sets both inheriting
                        // RPE 7 are the same prescription written once.
                        effort: effort,
                        type: set.type
                    )
                )
            }
        }
        return groups
    }

    /// A run of identically prescribed consecutive sets.
    public struct SetGroup: Hashable, Sendable {
        public var count: Int
        public var reps: Int?
        public var load: LoadPrescription?
        public var effort: EffortTarget?
        public var type: SetType?

        public init(
            count: Int,
            reps: Int? = nil,
            load: LoadPrescription? = nil,
            effort: EffortTarget? = nil,
            type: SetType? = nil
        ) {
            self.count = count
            self.reps = reps
            self.load = load
            self.effort = effort
            self.type = type
        }
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
    /// Where this workout came from. `nil` means it was logged in this app;
    /// anything else names the translation that produced it (`"strong-csv"`).
    ///
    /// Provenance, not a category. It earns its place twice: a reload can
    /// replace exactly what a given source wrote instead of doubling the log,
    /// and history can say a session was imported rather than letting five
    /// years of someone else's app read as though it were tracked here.
    public var source: String?

    public init(
        id: UUID = UUID(),
        exercises: [[WorkoutExercise]]? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        notes: String? = nil,
        usernotes: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.exercises = exercises
        self.startTime = startTime
        self.endTime = endTime
        self.notes = notes
        self.usernotes = usernotes
        self.source = source
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

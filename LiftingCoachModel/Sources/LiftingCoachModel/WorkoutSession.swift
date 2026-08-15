import Foundation

/// Where an exercise sits inside a `Workout`: which superset group, and its
/// position within that group.
public struct ExerciseAddress: Hashable, Sendable {
    public var group: Int
    public var index: Int

    public init(group: Int, index: Int) {
        self.group = group
        self.index = index
    }
}

/// The live state of a workout in progress — the model behind the Workout
/// Tracker screen.
///
/// Everything the tracker does to a workout goes through here rather than
/// mutating `Workout` directly, so the rules (what's active, what rest is owed,
/// how a prescription becomes a logged set) live in one tested place instead of
/// spread across view code.
///
/// Deliberately a value type with no persistence and no clock of its own: every
/// mutation takes the current date as a parameter, which is what makes the
/// behavior below testable without waiting on real time.
public struct WorkoutSession: Equatable, Sendable {
    public private(set) var workout: Workout

    /// The block this workout belongs to, if any — supplies `defaultRestTimes`.
    public var block: WorkoutBlock?
    /// The lifter, if known — supplies `maxLifts` for resolving `%1RM`.
    public var user: User?
    /// Final fallback when neither the set nor the block specifies a rest time.
    public var appDefaultRestTime: Int

    public init(
        workout: Workout,
        block: WorkoutBlock? = nil,
        user: User? = nil,
        appDefaultRestTime: Int = 120
    ) {
        self.workout = workout
        self.block = block
        self.user = user
        self.appDefaultRestTime = appDefaultRestTime
    }

    // MARK: - Starting

    /// Materializes a live workout from a prescription.
    ///
    /// Each `PlannedSet` becomes a `WorkoutSet` that carries its prescription
    /// forward in `plannedFrom`, so planned-vs-actual can be compared later
    /// without needing the plan in hand. Weights are pre-filled where they can be
    /// resolved — an absolute load, or a `%1RM` against a recorded max. An RPE
    /// prescription resolves to no weight on purpose: picking a number for it
    /// needs rep-range-aware history the model doesn't have yet, so the lifter
    /// enters it and the prescription stays visible alongside.
    public static func start(
        from planned: PlannedWorkout,
        block: WorkoutBlock? = nil,
        user: User? = nil,
        at date: Date = Date(),
        appDefaultRestTime: Int = 120
    ) -> WorkoutSession {
        let groups = (planned.exercises ?? []).map { group in
            group.map { plannedExercise in
                WorkoutExercise(
                    exercise: plannedExercise.exercise,
                    sets: (plannedExercise.sets ?? []).map { plannedSet in
                        WorkoutSet(
                            reps: plannedSet.reps,
                            weight: plannedSet.load?.resolvedWeight(
                                oneRepMax: user?.maxLifts?[plannedExercise.exercise.id]
                            ),
                            complete: false,
                            type: plannedSet.type,
                            notes: plannedSet.notes,
                            plannedFrom: plannedSet
                        )
                    },
                    notes: plannedExercise.notes
                )
            }
        }

        return WorkoutSession(
            workout: Workout(exercises: groups, startTime: date, notes: planned.notes),
            block: block,
            user: user,
            appDefaultRestTime: appDefaultRestTime
        )
    }

    /// An ad-hoc workout with no prescription behind it — `Ideas.md` calls out
    /// recording workouts outside the normal programming as a requirement.
    public static func adHoc(
        at date: Date = Date(),
        block: WorkoutBlock? = nil,
        user: User? = nil,
        appDefaultRestTime: Int = 120
    ) -> WorkoutSession {
        WorkoutSession(
            workout: Workout(exercises: [], startTime: date),
            block: block,
            user: user,
            appDefaultRestTime: appDefaultRestTime
        )
    }

    // MARK: - Reading

    public var exerciseGroups: [[WorkoutExercise]] { workout.exercises ?? [] }

    public var isComplete: Bool {
        !workout.allSets.isEmpty && workout.allSets.allSatisfy { $0.complete == true }
    }

    /// Completed vs. total logged sets, for a progress readout.
    public var progress: (completed: Int, total: Int) {
        let sets = workout.allSets
        return (sets.filter { $0.complete == true }.count, sets.count)
    }

    /// The exercise the tracker should highlight: the one holding the first set
    /// that hasn't been checked off yet.
    ///
    /// `nil` once everything is done, which is the tracker's cue to offer
    /// finishing rather than to keep highlighting a finished exercise.
    public var activeExercise: ExerciseAddress? {
        for (groupIndex, group) in exerciseGroups.enumerated() {
            for (index, exercise) in group.enumerated() {
                if (exercise.sets ?? []).contains(where: { $0.complete != true }) {
                    return ExerciseAddress(group: groupIndex, index: index)
                }
            }
        }
        return nil
    }

    /// The next set to be performed, if any.
    public var nextSet: WorkoutSet? {
        guard let address = activeExercise else { return nil }
        return exercise(at: address)?.sets?.first { $0.complete != true }
    }

    public func exercise(at address: ExerciseAddress) -> WorkoutExercise? {
        guard address.group < exerciseGroups.count else { return nil }
        let group = exerciseGroups[address.group]
        guard address.index < group.count else { return nil }
        return group[address.index]
    }

    /// How long the lifter should rest after the given set: the prescription's
    /// own `restTime`, then the block's default for that set type, then the app
    /// default. Mirrors `WorkoutBlock.restTime(for:appDefault:)` for logged sets.
    public func restTarget(afterSetWith id: UUID) -> Int {
        guard let set = workout.allSets.first(where: { $0.id == id }) else {
            return appDefaultRestTime
        }
        if let planned = set.plannedFrom {
            return block?.restTime(for: planned, appDefault: appDefaultRestTime)
                ?? planned.restTime
                ?? appDefaultRestTime
        }
        if let type = set.type, let blockDefault = block?.defaultRestTimes?[type] {
            return blockDefault
        }
        return appDefaultRestTime
    }

    // MARK: - Logging

    /// Marks a set done, recording what was actually lifted.
    ///
    /// `reps`/`weight`/`rpe` are optional overrides — passing `nil` keeps
    /// whatever the set already carries (typically the prescribed value carried
    /// over by `start(from:)`), so checking off an as-prescribed set needs no
    /// arguments at all. That's the common case during a workout, and it's the
    /// interaction Workout Tracker.md cares most about being frictionless.
    ///
    /// Also records `restTime` as the seconds elapsed since the previously
    /// completed set — the rest that *preceded* this one. That's the interval the
    /// rest timer was actually counting, and the only one measurable at the
    /// moment a set is logged.
    @discardableResult
    public mutating func completeSet(
        id: UUID,
        reps: Int? = nil,
        weight: Measurement<UnitMass>? = nil,
        rpe: Float? = nil,
        notes: String? = nil,
        at date: Date = Date()
    ) -> Bool {
        let previousCompletion = workout.allSets
            .filter { $0.complete == true }
            .compactMap(\.timeComplete)
            .max()

        return mutateSet(id: id) { set in
            set.complete = true
            set.timeComplete = date
            if let reps { set.reps = reps }
            if let weight { set.weight = weight }
            if let rpe { set.rpe = rpe }
            if let notes { set.usernotes = notes }
            if let previousCompletion {
                set.restTime = max(0, Int(date.timeIntervalSince(previousCompletion)))
            }
        }
    }

    /// Undoes a completion.
    ///
    /// Clears `timeComplete` and the measured `restTime` along with it — leaving
    /// a completion timestamp on a set that isn't complete would quietly corrupt
    /// the rest calculation for every set logged afterward. Reps, weight, and RPE
    /// are kept: the lifter un-checking a set almost never means they want the
    /// numbers they typed thrown away.
    @discardableResult
    public mutating func uncompleteSet(id: UUID) -> Bool {
        mutateSet(id: id) { set in
            set.complete = false
            set.timeComplete = nil
            set.restTime = nil
        }
    }

    @discardableResult
    public mutating func updateSet(
        id: UUID,
        _ change: (inout WorkoutSet) -> Void
    ) -> Bool {
        mutateSet(id: id, change)
    }

    // MARK: - Editing the workout mid-session

    /// Appends a set to an exercise, copying the shape of its last set so adding
    /// a fourth set of the same thing doesn't mean re-entering everything.
    ///
    /// The copy deliberately drops `plannedFrom`: an added set was not
    /// prescribed, and claiming otherwise would inflate plan adherence.
    @discardableResult
    public mutating func addSet(toExerciseWith exerciseID: UUID) -> UUID? {
        var newID: UUID?
        mutateExercise(id: exerciseID) { exercise in
            let template = exercise.sets?.last
            let new = WorkoutSet(
                reps: template?.reps,
                weight: template?.weight,
                complete: false,
                type: template?.type ?? .working
            )
            newID = new.id
            exercise.sets = (exercise.sets ?? []) + [new]
        }
        return newID
    }

    @discardableResult
    public mutating func deleteSet(id: UUID) -> Bool {
        var removed = false
        forEachExercise { exercise in
            guard !removed, let index = exercise.sets?.firstIndex(where: { $0.id == id }) else { return }
            exercise.sets?.remove(at: index)
            removed = true
        }
        return removed
    }

    /// Adds an exercise as its own (non-superset) group at the end.
    @discardableResult
    public mutating func addExercise(_ exercise: Exercise, sets: Int = 0) -> UUID {
        let new = WorkoutExercise(
            exercise: exercise,
            sets: (0..<sets).map { _ in WorkoutSet(complete: false, type: .working) }
        )
        workout.exercises = (workout.exercises ?? []) + [[new]]
        return new.id
    }

    @discardableResult
    public mutating func deleteExercise(id: UUID) -> Bool {
        guard var groups = workout.exercises else { return false }
        var removed = false
        for groupIndex in groups.indices {
            if let index = groups[groupIndex].firstIndex(where: { $0.id == id }) {
                groups[groupIndex].remove(at: index)
                removed = true
                break
            }
        }
        // Drop a superset group that just lost its last member, so the workout
        // doesn't accumulate empty groups that render as blank rows.
        groups.removeAll(where: \.isEmpty)
        workout.exercises = groups
        return removed
    }

    /// Reorders superset groups — the drag-to-reorder interaction in
    /// Workout Tracker.md.
    public mutating func moveGroup(from source: Int, to destination: Int) {
        guard var groups = workout.exercises,
              groups.indices.contains(source),
              destination >= 0, destination <= groups.count,
              source != destination
        else { return }

        let group = groups.remove(at: source)
        // Removing shifts everything after `source` down by one, so a move to a
        // later position needs its target adjusted or the item lands one slot
        // too far right.
        let adjusted = destination > source ? destination - 1 : destination
        groups.insert(group, at: min(adjusted, groups.count))
        workout.exercises = groups
    }

    // MARK: - Finishing

    /// Ends the workout.
    ///
    /// Incomplete sets are removed rather than saved as zeroes — an unfinished
    /// set is one that didn't happen, and keeping it would drag down every
    /// adherence and volume number computed from history later.
    public mutating func finish(at date: Date = Date()) {
        forEachExercise { exercise in
            exercise.sets?.removeAll { $0.complete != true }
        }
        workout.exercises = (workout.exercises ?? []).map { group in
            group.filter { !($0.sets ?? []).isEmpty }
        }
        workout.exercises?.removeAll(where: \.isEmpty)
        workout.endTime = date
    }

    // MARK: - Mutation helpers

    private mutating func mutateSet(id: UUID, _ change: (inout WorkoutSet) -> Void) -> Bool {
        var changed = false
        forEachExercise { exercise in
            guard !changed, let index = exercise.sets?.firstIndex(where: { $0.id == id }) else { return }
            change(&exercise.sets![index])
            changed = true
        }
        return changed
    }

    private mutating func mutateExercise(id: UUID, _ change: (inout WorkoutExercise) -> Void) {
        forEachExercise { exercise in
            guard exercise.id == id else { return }
            change(&exercise)
        }
    }

    private mutating func forEachExercise(_ body: (inout WorkoutExercise) -> Void) {
        guard var groups = workout.exercises else { return }
        for groupIndex in groups.indices {
            for index in groups[groupIndex].indices {
                body(&groups[groupIndex][index])
            }
        }
        workout.exercises = groups
    }
}

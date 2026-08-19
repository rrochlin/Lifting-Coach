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
    /// without needing the plan in hand. Two resolutions happen here:
    ///
    /// - **Weight** is pre-filled where the load resolves — an absolute load, or
    ///   a percentage against a max the lifter actually has recorded. A load that
    ///   can't resolve stays blank and the prescription displays as-is.
    /// - **Effort** is materialized into the snapshot (`set.effort ??
    ///   exercise.effort`), because the snapshot is all history keeps — an
    ///   exercise-level target would otherwise be lost with the plan.
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
                        var snapshot = plannedSet
                        snapshot.effort = plannedExercise.resolvedEffort(for: plannedSet)
                        return WorkoutSet(
                            reps: plannedSet.reps,
                            weight: plannedSet.load?.resolvedWeight { reference in
                                user?.max(reference, for: plannedExercise.exercise.id)
                            },
                            complete: false,
                            type: plannedSet.type,
                            notes: plannedSet.notes,
                            plannedFrom: snapshot
                        )
                    },
                    // Carried forward, not looked up later: how the lift was
                    // prescribed that day ("heavy, paused") is part of what was
                    // done, and history has to stay readable without the plan.
                    variant: plannedExercise.variant,
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

    /// The exercise a given logged set belongs to, wherever it sits in the
    /// grouping — used to resolve which lift a completed set counts toward
    /// (e.g. for achieved-max tracking) without the caller needing to know the
    /// superset structure.
    public func exercise(containingSetID id: UUID) -> WorkoutExercise? {
        exerciseGroups.flatMap { $0 }.first { ($0.sets ?? []).contains { $0.id == id } }
    }

    public func exercise(at address: ExerciseAddress) -> WorkoutExercise? {
        guard address.group < exerciseGroups.count else { return nil }
        let group = exerciseGroups[address.group]
        guard address.index < group.count else { return nil }
        return group[address.index]
    }

    /// How long the lifter should rest after the given set: their own override
    /// for this set, then the prescription's `restTime`, then the block's
    /// default for that set type, then the app default. Mirrors
    /// `WorkoutBlock.restTime(for:appDefault:)` for logged sets.
    ///
    /// The override wins outright, and on purpose — the lifter saying "three
    /// and a half minutes on this one" is the most specific instruction in the
    /// chain, and the app doesn't get to average it against the program
    /// (Core Tenets §1).
    public func restTarget(afterSetWith id: UUID) -> Int {
        guard let set = workout.allSets.first(where: { $0.id == id }) else {
            return appDefaultRestTime
        }
        if let override = set.restOverride { return override }
        return prescribedRest(afterSetWith: id)
    }

    /// What the plan asks for after this set, ignoring any override the lifter
    /// has set. Lets the rest control offer "back to prescribed" without the
    /// view having to re-walk the fallback chain itself.
    public func prescribedRest(afterSetWith id: UUID) -> Int {
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
    /// Deliberately does **not** record how long the lifter rested. The interval
    /// between two completion timestamps isn't rest — it's rest plus however long
    /// it took to reach for the phone, so it always reads long, and always in the
    /// same direction. A number that's wrong the same way every time is worse
    /// than no number, because it looks like data. See `WorkoutSet.restTime`.
    @discardableResult
    public mutating func completeSet(
        id: UUID,
        reps: Int? = nil,
        weight: Measurement<UnitMass>? = nil,
        rpe: Float? = nil,
        notes: String? = nil,
        at date: Date = Date()
    ) -> Bool {
        mutateSet(id: id) { set in
            set.complete = true
            set.timeComplete = date
            if let reps { set.reps = reps }
            if let weight { set.weight = weight }
            if let rpe { set.rpe = rpe }
            if let notes { set.usernotes = notes }
        }
    }

    /// Undoes a completion.
    ///
    /// Reps, weight, and RPE are kept: the lifter un-checking a set almost never
    /// means they want the numbers they typed thrown away.
    @discardableResult
    public mutating func uncompleteSet(id: UUID) -> Bool {
        mutateSet(id: id) { set in
            set.complete = false
            set.timeComplete = nil
        }
    }

    @discardableResult
    public mutating func updateSet(
        id: UUID,
        _ change: (inout WorkoutSet) -> Void
    ) -> Bool {
        mutateSet(id: id, change)
    }

    /// Sets (or clears, with `nil`) the lifter's own rest for one set.
    ///
    /// Clamped at zero — "no rest here" is a legitimate thing to want and lands
    /// on a timer that's already finished, but negative rest isn't a duration.
    /// Rest stays a per-set value: back-off sets after a heavy triple don't
    /// need the same three minutes the triple did, and the whole point of
    /// tuning it is that the plan's uniform number is a starting point
    /// (Core Tenets §1).
    @discardableResult
    public mutating func setRest(_ seconds: Int?, forSetWith id: UUID) -> Bool {
        mutateSet(id: id) { set in
            set.restOverride = seconds.map { max(0, $0) }
        }
    }

    /// General mutator for exercise-level fields (currently just `notes`/
    /// `usernotes`) — the exercise-level counterpart to `updateSet`.
    @discardableResult
    public mutating func updateExercise(
        id: UUID,
        _ change: (inout WorkoutExercise) -> Void
    ) -> Bool {
        var changed = false
        mutateExercise(id: id) { exercise in
            change(&exercise)
            changed = true
        }
        return changed
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
                type: template?.type ?? .working,
                // Carried, unlike `plannedFrom`: a tuned rest is the lifter's
                // own instruction for this lift today, and re-tuning it on
                // every added set is exactly the friction being removed.
                restOverride: template?.restOverride
            )
            newID = new.id
            exercise.sets = (exercise.sets ?? []) + [new]
        }
        return newID
    }

    /// Appends a drop set — same movement, immediately after, lighter.
    ///
    /// Copies reps from the set above and deliberately not its weight: a drop
    /// is by definition lighter than what it drops from, so pre-filling the
    /// working weight would mean clearing it every time. Same reasoning as
    /// `addWarmupSet`, in the other direction.
    ///
    /// Typed `.drop`, which is load-bearing the same way `.warmup` is:
    /// `AchievedMaxUpdate` only records a max from a `.working` set, and a
    /// back-off after a top single is not a maximal effort.
    @discardableResult
    public mutating func addDropSet(toExerciseWith exerciseID: UUID) -> UUID? {
        var newID: UUID?
        mutateExercise(id: exerciseID) { exercise in
            let template = exercise.sets?.last
            let new = WorkoutSet(
                reps: template?.reps,
                complete: false,
                type: .drop,
                restOverride: template?.restOverride,
                unit: template?.unit
            )
            newID = new.id
            exercise.sets = (exercise.sets ?? []) + [new]
        }
        return newID
    }

    /// Prepends a warmup set to an exercise — the ramp-up that gets you to the
    /// first programmed set.
    ///
    /// A program prescribes working sets; how a lifter gets to 315 is theirs to
    /// decide on the day, and it belongs *above* the prescription rather than
    /// appended after it. Typed `.warmup` because that's what the button that
    /// calls this says it makes, and the type is load-bearing: a heavy last
    /// ramp-up single is not a maximal effort, and `AchievedMaxUpdate` is right
    /// to ignore it.
    ///
    /// Deliberately empty rather than a copy of the first set. `addSet` copies
    /// the set above it because a fourth set of the same thing usually is the
    /// same thing; a warmup is by definition lighter than what follows, so
    /// pre-filling the working weight would mean clearing it every time. The
    /// rest carries over for the same reason it does on `addSet`.
    @discardableResult
    public mutating func addWarmupSet(toExerciseWith exerciseID: UUID) -> UUID? {
        var newID: UUID?
        mutateExercise(id: exerciseID) { exercise in
            let new = WorkoutSet(
                complete: false,
                type: .warmup,
                restOverride: exercise.sets?.first?.restOverride
            )
            newID = new.id
            exercise.sets = [new] + (exercise.sets ?? [])
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

    // MARK: - Supersets

    /// Pairs two exercises into one superset group, moving `id` in beside
    /// `other` and appending it after.
    ///
    /// The nesting has always been in the model (`[[WorkoutExercise]]`) and in
    /// the schema (`groupIndex`/`position`), but nothing could *form* a group —
    /// a superset could only arrive from a plan. Deciding to pair two lifts is
    /// something that happens mid-workout, at the rack, and it's the lifter's
    /// call (Core Tenets §1).
    ///
    /// Leaves `workout.exercises` dense. That matters beyond tidiness:
    /// `WorkoutStore` rebuilds the nesting on read by watching `groupIndex`
    /// advance, so a skipped index doesn't round-trip — it silently re-nests
    /// the workout into the wrong shape.
    ///
    /// Returns false when either id is unknown or the two already share a
    /// group, so a no-op can't be mistaken for a change worth persisting.
    @discardableResult
    public mutating func superset(id: UUID, with other: UUID) -> Bool {
        guard var groups = workout.exercises,
              let source = address(of: id, in: groups),
              let target = address(of: other, in: groups),
              source.group != target.group
        else { return false }

        let moved = groups[source.group].remove(at: source.index)
        // Emptying the source group shifts every later group down by one —
        // including the target's, when the target sat after the source.
        var destination = target.group
        if groups[source.group].isEmpty {
            groups.remove(at: source.group)
            if destination > source.group { destination -= 1 }
        }
        groups[destination].append(moved)

        workout.exercises = groups
        return true
    }

    /// Pulls an exercise out of its superset into a group of its own.
    ///
    /// Lands immediately after the group it left rather than at the end of the
    /// workout: an exercise that jumps to the bottom of the list when you
    /// unpair it reads as having been deleted and re-added somewhere else.
    ///
    /// Returns false for an unknown id, or one already alone in its group.
    @discardableResult
    public mutating func ungroup(id: UUID) -> Bool {
        guard var groups = workout.exercises,
              let source = address(of: id, in: groups),
              groups[source.group].count > 1
        else { return false }

        let moved = groups[source.group].remove(at: source.index)
        groups.insert([moved], at: source.group + 1)

        workout.exercises = groups
        return true
    }

    /// Where an exercise currently sits.
    ///
    /// Private, because everything else addresses exercises by id: an
    /// `ExerciseAddress` is invalidated by the very next mutation, so it's a
    /// local intermediate rather than something to hold onto.
    private func address(of id: UUID, in groups: [[WorkoutExercise]]) -> ExerciseAddress? {
        for (groupIndex, group) in groups.enumerated() {
            if let index = group.firstIndex(where: { $0.id == id }) {
                return ExerciseAddress(group: groupIndex, index: index)
            }
        }
        return nil
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

    /// Reorders sets within a single exercise — mirrors `moveGroup` for whole
    /// exercises. Out-of-range or no-op moves are ignored, not a crash.
    public mutating func moveSet(from source: Int, to destination: Int, within exerciseID: UUID) {
        mutateExercise(id: exerciseID) { exercise in
            guard var sets = exercise.sets,
                  sets.indices.contains(source),
                  destination >= 0, destination <= sets.count,
                  source != destination
            else { return }

            let set = sets.remove(at: source)
            // Same shift-adjustment as moveGroup: removing shifts everything
            // after `source` down by one.
            let adjusted = destination > source ? destination - 1 : destination
            sets.insert(set, at: min(adjusted, sets.count))
            exercise.sets = sets
        }
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

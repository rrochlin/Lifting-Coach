import Foundation

/// A planned workout being authored — the model behind the Workout Planner's
/// day editor.
///
/// The counterpart to `WorkoutSession`, and deliberately shaped the same way:
/// a value type with no persistence and no clock, so the editing rules live in
/// one tested place instead of spread across view code.
///
/// The one structural difference is `original`. The tracker saves after every
/// mutation, because a workout the OS kills mid-session must be recoverable.
/// Planning is the opposite case — it's deliberate authoring, and a half-typed
/// percentage shouldn't become the plan. So edits accumulate here and only
/// `markSaved()` (called after a successful write) moves the baseline, which
/// makes `hasUnsavedChanges` exact: undoing an edit by hand clears it, rather
/// than leaving a dirty flag stuck on.
public struct PlannedWorkoutDraft: Equatable, Sendable {
    /// The working copy — what the editor shows and mutates.
    public private(set) var workout: PlannedWorkout
    /// What was last written. Compared against, never edited.
    public private(set) var original: PlannedWorkout

    public init(_ workout: PlannedWorkout) {
        self.workout = workout
        self.original = workout
    }

    // MARK: - Reading

    public var exerciseGroups: [[PlannedExercise]] { workout.exercises ?? [] }

    /// Whether the draft differs from what was last saved.
    ///
    /// A structural comparison rather than a flag set by each mutation: typing
    /// a weight and typing it back leaves nothing to save, and shouldn't warn
    /// on the way out.
    public var hasUnsavedChanges: Bool { workout != original }

    public func exercise(id: UUID) -> PlannedExercise? {
        exerciseGroups.flatMap { $0 }.first { $0.id == id }
    }

    /// The exercise a planned set belongs to, wherever it sits in the grouping.
    /// The set alone doesn't carry the effort target that applies to it, so
    /// anything displaying a set needs its exercise too.
    public func exercise(containingSetID id: UUID) -> PlannedExercise? {
        exerciseGroups.flatMap { $0 }.first { ($0.sets ?? []).contains { $0.id == id } }
    }

    public func set(id: UUID) -> PlannedSet? {
        workout.allSets.first { $0.id == id }
    }

    /// The effort target in force for a set: its own override, else the
    /// containing exercise's. `nil` means no effort is prescribed at all, which
    /// is a legitimate prescription rather than a gap (Core Tenets §2).
    public func resolvedEffort(forSetWith id: UUID) -> EffortTarget? {
        guard let exercise = exercise(containingSetID: id), let set = set(id: id) else {
            return nil
        }
        return exercise.resolvedEffort(for: set)
    }

    // MARK: - Save lifecycle

    /// Rebases onto the current contents after a successful write. Call this
    /// *after* persistence succeeds — calling it on a failed save would report
    /// unsaved work as saved.
    public mutating func markSaved() {
        original = workout
    }

    /// Throws away every unsaved edit.
    public mutating func revert() {
        workout = original
    }

    /// Adopts a workout reloaded from the store, discarding unsaved edits.
    public mutating func reload(_ workout: PlannedWorkout) {
        self.workout = workout
        self.original = workout
    }

    // MARK: - Workout-level editing

    /// The plan's own label for the day ("Week 1 Mon — Bench + Squat"), which
    /// doubles as its notes field. One string rather than two: that's what the
    /// source program carries, and what every list of days shows as its title.
    public mutating func setNotes(_ notes: String?) {
        workout.notes = (notes?.isEmpty == true) ? nil : notes
    }

    // MARK: - Exercise editing

    /// Appends an exercise as its own (non-superset) group at the end.
    ///
    /// New sets carry reps but no load and no effort: an exercise just added
    /// hasn't been prescribed yet, and pre-filling a percentage would put a
    /// number in the plan that nobody chose.
    @discardableResult
    public mutating func addExercise(
        _ exercise: Exercise,
        sets: Int = 3,
        reps: Int = 5
    ) -> UUID {
        let new = PlannedExercise(
            exercise: exercise,
            sets: (0..<sets).map { _ in PlannedSet(reps: reps, type: .working) }
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
        // A superset group that just lost its last member would otherwise
        // render as a blank row.
        groups.removeAll(where: \.isEmpty)
        workout.exercises = groups
        return removed
    }

    @discardableResult
    public mutating func updateExercise(
        id: UUID,
        _ change: (inout PlannedExercise) -> Void
    ) -> Bool {
        var changed = false
        forEachExercise { exercise in
            guard exercise.id == id else { return }
            change(&exercise)
            changed = true
        }
        return changed
    }

    /// Reorders superset groups. Mirrors `WorkoutSession.moveGroup`, including
    /// its index adjustment.
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

    // MARK: - Set editing

    /// Appends a set, copying the shape of the exercise's last set.
    ///
    /// Programming is repetitive by nature — a fourth set of the same thing
    /// shouldn't mean re-entering the prescription. Unlike the tracker's
    /// equivalent there's nothing to deliberately drop: a planned set copied
    /// from a planned set is still entirely plan.
    @discardableResult
    public mutating func addSet(toExerciseWith exerciseID: UUID) -> UUID? {
        var newID: UUID?
        updateExercise(id: exerciseID) { exercise in
            let template = exercise.sets?.last
            let new = PlannedSet(
                reps: template?.reps ?? 5,
                type: template?.type ?? .working,
                load: template?.load,
                effort: template?.effort,
                restTime: template?.restTime
            )
            newID = new.id
            exercise.sets = (exercise.sets ?? []) + [new]
        }
        return newID
    }

    /// Writes an exercise's working sets in one statement: `count` sets, all at
    /// `reps` and `load`.
    ///
    /// Programming is written as "4×5 @ 225", and authoring it one row at a
    /// time was the complaint — "we should be able to program sets x weight x
    /// reps to make writing easier if we're doing the same weight for multiple
    /// sets". The block overview has always *read* the plan back this way
    /// (`PlannedExercise.setGroups` collapses identical sets into "4×5 · 225
    /// lb"); this is the same shape on the way in.
    ///
    /// **Working sets only.** Warmups and drops are a different kind, and "4×5
    /// @ 225" is never an instruction to delete a ramp — so they stay exactly
    /// where they are, in their existing order relative to the working sets.
    ///
    /// **Resizes rather than replaces.** Surviving sets keep their identity and
    /// their own effort and rest, so raising a 3×5 to 4×5 doesn't silently drop
    /// a per-set RPE the author had written; new sets inherit both from the
    /// first working set, which is what a fourth set of the same thing means.
    /// Trimming removes from the end.
    public mutating func setWorkingSets(
        count: Int,
        reps: Int?,
        load: LoadPrescription?,
        toExerciseWith exerciseID: UUID
    ) {
        guard count >= 0 else { return }
        updateExercise(id: exerciseID) { exercise in
            let existing = exercise.sets ?? []
            let working = existing.filter { ($0.type ?? .working) == .working }
            let template = working.first

            var rebuilt: [PlannedSet] = []
            for index in 0..<count {
                if index < working.count {
                    var set = working[index]
                    set.reps = reps
                    set.load = load
                    rebuilt.append(set)
                } else {
                    rebuilt.append(PlannedSet(
                        reps: reps,
                        type: .working,
                        load: load,
                        effort: template?.effort,
                        restTime: template?.restTime
                    ))
                }
            }

            // Rebuilt working sets are dealt back into the positions working
            // sets already occupied, so a warmup written above them stays above
            // them. Anything left over lands where the last working set was —
            // or at the end, for an exercise that had none.
            var result: [PlannedSet] = []
            var next = rebuilt.makeIterator()
            var placedAll = false
            for set in existing {
                if (set.type ?? .working) == .working {
                    if let replacement = next.next() {
                        result.append(replacement)
                    }
                    // The last original working set is where any additional
                    // sets go, rather than after a trailing drop set.
                    if set.id == working.last?.id {
                        while let extra = next.next() { result.append(extra) }
                        placedAll = true
                    }
                } else {
                    result.append(set)
                }
            }
            if !placedAll {
                while let extra = next.next() { result.append(extra) }
            }
            exercise.sets = result
        }
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

    @discardableResult
    public mutating func updateSet(
        id: UUID,
        _ change: (inout PlannedSet) -> Void
    ) -> Bool {
        var changed = false
        forEachExercise { exercise in
            guard !changed, let index = exercise.sets?.firstIndex(where: { $0.id == id }) else { return }
            change(&exercise.sets![index])
            changed = true
        }
        return changed
    }

    /// Reorders sets within one exercise.
    public mutating func moveSet(from source: Int, to destination: Int, within exerciseID: UUID) {
        updateExercise(id: exerciseID) { exercise in
            guard var sets = exercise.sets,
                  sets.indices.contains(source),
                  destination >= 0, destination <= sets.count,
                  source != destination
            else { return }

            let set = sets.remove(at: source)
            let adjusted = destination > source ? destination - 1 : destination
            sets.insert(set, at: min(adjusted, sets.count))
            exercise.sets = sets
        }
    }

    /// Applies a rest time to every set of an exercise.
    ///
    /// Rest is stored per set (`PlannedSet.restTime`), but it's *written* per
    /// exercise — "3 minutes on squats" is one instruction. This is the
    /// authoring gesture for that; the per-set field stays the storage.
    public mutating func setRestTime(_ seconds: Int?, forExerciseWith exerciseID: UUID) {
        updateExercise(id: exerciseID) { exercise in
            exercise.sets = (exercise.sets ?? []).map { set in
                var set = set
                set.restTime = seconds
                return set
            }
        }
    }

    /// The rest time shared by every set of an exercise, or `nil` when they
    /// disagree (or none is set) — so the UI can show a value without
    /// pretending a mixed prescription is uniform.
    public func uniformRestTime(forExerciseWith exerciseID: UUID) -> Int? {
        guard let sets = exercise(id: exerciseID)?.sets, !sets.isEmpty else { return nil }
        let times = Set(sets.map { $0.restTime })
        guard times.count == 1 else { return nil }
        return times.first ?? nil
    }

    // MARK: - Mutation helpers

    private mutating func forEachExercise(_ body: (inout PlannedExercise) -> Void) {
        guard var groups = workout.exercises else { return }
        for groupIndex in groups.indices {
            for index in groups[groupIndex].indices {
                body(&groups[groupIndex][index])
            }
        }
        workout.exercises = groups
    }
}

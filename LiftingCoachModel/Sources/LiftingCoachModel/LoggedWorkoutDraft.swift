import Foundation

/// A logged workout being corrected — the model behind the History detail
/// screen's edit mode.
///
/// The third editing model in this package, and deliberately the planner's
/// shape rather than the tracker's. `WorkoutSession` saves after every
/// mutation because a session the OS kills mid-workout has to be recoverable;
/// there is nothing to recover here. Correcting a set logged in March is
/// authoring — `notes/Feedback.md` asks to "fix mislogged sets" — and a
/// half-typed weight shouldn't overwrite five years of history on its way to
/// being finished. So edits accumulate and land on an explicit save, exactly
/// like `PlannedWorkoutDraft`.
///
/// What it deliberately cannot change:
/// - **`source`.** Provenance is a fact about where a row came from. Fixing a
///   rep count in an imported workout doesn't make it a workout logged here.
/// - **`plannedFrom`.** The prescription snapshot records what was *asked for*.
///   A lifter correcting what they actually lifted is not rewriting the
///   program, and letting an edit reach into it would make adherence lie.
/// - **Which exercise a block is.** Swapping identity after the fact is a real
///   want ("I logged this under the wrong lift") but it needs the picker and a
///   decision about the achieved maxes it invalidates. Left out rather than
///   half-built.
public struct LoggedWorkoutDraft: Equatable, Sendable {
    /// The working copy — what the editor shows and mutates.
    public private(set) var workout: Workout
    /// What was last written. Compared against, never edited.
    public private(set) var original: Workout

    public init(_ workout: Workout) {
        self.workout = workout
        self.original = workout
    }

    // MARK: - Reading

    public var exerciseGroups: [[WorkoutExercise]] { workout.exercises ?? [] }

    /// Whether the draft differs from what was last saved.
    ///
    /// Structural, not a dirty flag: typing a weight and typing it back leaves
    /// nothing to save and shouldn't warn on the way out.
    public var hasUnsavedChanges: Bool { workout != original }

    /// Nothing left in it. The screen offers to delete the workout rather than
    /// saving an empty shell — a session with no exercises is not a record of
    /// anything, and leaving it in history is worse than removing it.
    public var isEmpty: Bool {
        exerciseGroups.allSatisfy(\.isEmpty)
    }

    public func exercise(id: UUID) -> WorkoutExercise? {
        exerciseGroups.flatMap { $0 }.first { $0.id == id }
    }

    public func exercise(containingSetID id: UUID) -> WorkoutExercise? {
        exerciseGroups.flatMap { $0 }.first { ($0.sets ?? []).contains { $0.id == id } }
    }

    public func set(id: UUID) -> WorkoutSet? {
        workout.allSets.first { $0.id == id }
    }

    // MARK: - Validity

    /// Something the draft says that can't be true of a logged workout.
    ///
    /// Reported rather than corrected. The app never fixes a lifter's entry on
    /// their behalf (Core Tenets §1) — moving the other end of the range to
    /// make an edit legal would quietly change a number nobody touched — so an
    /// invalid draft simply can't be saved, and says why.
    public enum Problem: Equatable, Sendable, CaseIterable {
        /// End time earlier than start time.
        case endsBeforeItStarts
        /// An end time but no start.
        case endsWithoutStarting

        public var message: String {
            switch self {
            case .endsBeforeItStarts: "This workout ends before it starts."
            case .endsWithoutStarting: "This workout has an end time but no start."
            }
        }
    }

    public var problems: [Problem] {
        var found: [Problem] = []
        if let end = workout.endTime {
            guard let start = workout.startTime else {
                found.append(.endsWithoutStarting)
                return found
            }
            if end < start { found.append(.endsBeforeItStarts) }
        }
        return found
    }

    public var canSave: Bool { problems.isEmpty }

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
    public mutating func reload(_ workout: Workout) {
        self.workout = workout
        self.original = workout
    }

    // MARK: - Workout-level editing

    /// The workout's own title. Empty collapses to `nil` rather than being
    /// stored as `""`, so "has a title" stays one question with one answer.
    public mutating func setTitle(_ title: String?) {
        workout.notes = normalized(title)
    }

    /// The lifter's own note on the session.
    public mutating func setUserNotes(_ notes: String?) {
        workout.usernotes = normalized(notes)
    }

    /// Corrects when the session began.
    ///
    /// Deliberately does not drag `endTime` with it. Both ends are shown and
    /// both are editable; a start that lands after the end is reported by
    /// `problems` and blocks the save, rather than being silently absorbed.
    public mutating func setStartTime(_ date: Date?) {
        workout.startTime = date
    }

    public mutating func setEndTime(_ date: Date?) {
        workout.endTime = date
    }

    // MARK: - Exercise editing

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
        // render as a blank row — and `WorkoutStore.hydrate` rebuilds the
        // nesting by watching `groupIndex` advance, so a gap re-nests the
        // workout into the wrong shape on the next launch.
        groups.removeAll(where: \.isEmpty)
        workout.exercises = groups
        return removed
    }

    @discardableResult
    public mutating func updateExercise(
        id: UUID,
        _ change: (inout WorkoutExercise) -> Void
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

    /// Appends a set that was performed but never logged.
    ///
    /// Copies the shape of the last set, including its weight — unlike the
    /// tracker's `addWarmupSet` and `addDropSet`, which deliberately drop it.
    /// Those two are *lighter by definition*, so pre-filling would mean
    /// clearing every time. This one is a set the lifter already did and simply
    /// didn't record, and the set before it is the best guess available.
    ///
    /// It lands **complete**, with no `timeComplete`. Complete because an
    /// unfinished set in a finished workout records nothing; no timestamp
    /// because there isn't one, and inventing one is fabricating data — the
    /// same rule the CSV importer follows.
    @discardableResult
    public mutating func addSet(toExerciseWith exerciseID: UUID) -> UUID? {
        var newID: UUID?
        updateExercise(id: exerciseID) { exercise in
            let template = exercise.sets?.last
            let new = WorkoutSet(
                reps: template?.reps,
                weight: template?.weight,
                complete: true,
                type: template?.type ?? .working,
                unit: template?.unit
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

    @discardableResult
    public mutating func updateSet(
        id: UUID,
        _ change: (inout WorkoutSet) -> Void
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

    // MARK: - Mutation helpers

    private func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

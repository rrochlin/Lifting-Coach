import Foundation
import Testing
@testable import LiftingCoachModel

private let squat = ExerciseCatalog.seed[0]
private let bench = ExerciseCatalog.seed[1]

private let noon = Date(timeIntervalSince1970: 1_770_000_000)
private func later(_ seconds: TimeInterval) -> Date { noon.addingTimeInterval(seconds) }

private func loggedSet(
    reps: Int? = 5,
    weight: Double? = 225,
    complete: Bool = true,
    type: SetType = .working
) -> WorkoutSet {
    WorkoutSet(
        reps: reps,
        weight: weight.map { Measurement(value: $0, unit: .pounds) },
        complete: complete,
        type: type
    )
}

private func loggedWorkout(
    _ exercises: [(Exercise, [WorkoutSet])] = [(squat, [loggedSet(), loggedSet()])]
) -> Workout {
    Workout(
        exercises: exercises.map { [WorkoutExercise(exercise: $0.0, sets: $0.1)] },
        startTime: noon,
        endTime: later(3600),
        notes: "Legs"
    )
}

@Suite("Editing a logged workout")
struct LoggedWorkoutDraftTests {

    @Test("A fresh draft has nothing to save")
    func startsClean() {
        let draft = LoggedWorkoutDraft(loggedWorkout())
        #expect(!draft.hasUnsavedChanges)
        #expect(draft.canSave)
        #expect(!draft.isEmpty)
    }

    @Test("Correcting a mislogged weight is an unsaved change")
    func editingASetIsDirty() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        let target = draft.workout.allSets[0].id

        let changed = draft.updateSet(id: target) { $0.weight = Measurement(value: 185, unit: .pounds) }
        #expect(changed)
        #expect(draft.hasUnsavedChanges)
        #expect(draft.set(id: target)?.weight?.value == 185)
    }

    /// The reason `hasUnsavedChanges` is a structural comparison rather than a
    /// flag each mutation sets: typing a number and typing it back leaves
    /// nothing to save, and shouldn't warn on the way out.
    @Test("Typing a value back restores a clean draft")
    func undoingByHandClearsTheFlag() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        let target = draft.workout.allSets[0].id

        draft.updateSet(id: target) { $0.reps = 3 }
        #expect(draft.hasUnsavedChanges)
        draft.updateSet(id: target) { $0.reps = 5 }
        #expect(!draft.hasUnsavedChanges)
    }

    @Test("Saving rebases, so the same edit isn't offered twice")
    func markSavedRebases() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        draft.updateSet(id: draft.workout.allSets[0].id) { $0.rpe = 9 }
        draft.markSaved()

        #expect(!draft.hasUnsavedChanges)
        #expect(draft.original.allSets[0].rpe == 9)
    }

    @Test("Reverting throws away every edit")
    func revertRestoresTheOriginal() {
        let workout = loggedWorkout()
        var draft = LoggedWorkoutDraft(workout)

        draft.setTitle("Something else")
        draft.deleteSet(id: draft.workout.allSets[0].id)
        draft.revert()

        #expect(draft.workout == workout)
        #expect(!draft.hasUnsavedChanges)
    }

    // MARK: - Times

    @Test("Start and stop times are correctable")
    func editsTimes() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        draft.setStartTime(later(600))
        draft.setEndTime(later(4200))

        #expect(draft.workout.startTime == later(600))
        #expect(draft.workout.endTime == later(4200))
        #expect(draft.canSave)
    }

    /// Reported, not corrected. Dragging the other end of the range to make an
    /// edit legal would silently change a number nobody touched — the app
    /// doesn't adjust a lifter's entry on their behalf (Core Tenets §1).
    @Test("A workout that ends before it starts can't be saved")
    func rejectsInvertedTimes() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        draft.setStartTime(later(7200))

        #expect(draft.problems == [.endsBeforeItStarts])
        #expect(!draft.canSave)
        // The end time is left exactly where it was.
        #expect(draft.workout.endTime == later(3600))
    }

    @Test("An end time with no start can't be saved")
    func rejectsEndWithoutStart() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        draft.setStartTime(nil)

        #expect(draft.problems == [.endsWithoutStarting])
        #expect(!draft.canSave)
    }

    @Test("A workout still in progress is valid — it just has no end yet")
    func allowsMissingEnd() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        draft.setEndTime(nil)

        #expect(draft.problems.isEmpty)
        #expect(draft.canSave)
    }

    // MARK: - Title and notes

    @Test("An emptied title becomes nil rather than an empty string")
    func normalizesTitle() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        draft.setTitle("   ")
        #expect(draft.workout.notes == nil)

        draft.setUserNotes("  felt strong  ")
        #expect(draft.workout.usernotes == "felt strong")
    }

    // MARK: - Sets

    /// A set added to a finished workout is one the lifter already did and
    /// simply didn't log, so it lands complete. No `timeComplete`, because
    /// there isn't one and inventing it would be fabricating data.
    @Test("An added set copies the last one and lands complete, untimed")
    func addSetCopiesForward() throws {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        let exerciseID = draft.exerciseGroups[0][0].id

        let newID = draft.addSet(toExerciseWith: exerciseID)
        let added = draft.set(id: try #require(newID))

        #expect(draft.exercise(id: exerciseID)?.sets?.count == 3)
        #expect(added?.reps == 5)
        #expect(added?.weight?.value == 225)
        #expect(added?.complete == true)
        #expect(added?.timeComplete == nil)
        #expect(added?.type == .working)
    }

    @Test("An added set on an empty exercise carries nothing over")
    func addSetToEmptyExercise() {
        var draft = LoggedWorkoutDraft(loggedWorkout([(bench, [])]))
        let exerciseID = draft.exerciseGroups[0][0].id

        _ = draft.addSet(toExerciseWith: exerciseID)
        let added = draft.exercise(id: exerciseID)?.sets?.first

        #expect(added?.reps == nil)
        #expect(added?.weight == nil)
        #expect(added?.complete == true)
        #expect(added?.type == .working)
    }

    @Test("Deleting a set removes only that set")
    func deletesOneSet() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        let target = draft.workout.allSets[0].id

        let deleted = draft.deleteSet(id: target)
        #expect(deleted)
        #expect(draft.workout.allSets.count == 1)
        #expect(draft.set(id: target) == nil)
    }

    @Test("Deleting an unknown set changes nothing")
    func deleteIsAMiss() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        let deleted = draft.deleteSet(id: UUID())
        #expect(!deleted)
        #expect(!draft.hasUnsavedChanges)
    }

    @Test("Sets reorder within their exercise")
    func movesSets() {
        var draft = LoggedWorkoutDraft(loggedWorkout([(squat, [
            loggedSet(reps: 5), loggedSet(reps: 3), loggedSet(reps: 1),
        ])]))
        let exerciseID = draft.exerciseGroups[0][0].id

        draft.moveSet(from: 0, to: 3, within: exerciseID)
        #expect(draft.exercise(id: exerciseID)?.sets?.map(\.reps) == [3, 1, 5])
    }

    // MARK: - Exercises

    /// `WorkoutStore.hydrate` rebuilds superset nesting by watching
    /// `groupIndex` advance, so an emptied group left in place would silently
    /// re-nest the workout into the wrong shape on the next launch.
    @Test("Deleting the last exercise of a group compacts the grouping")
    func deleteCompactsEmptyGroups() {
        var draft = LoggedWorkoutDraft(loggedWorkout([
            (squat, [loggedSet()]),
            (bench, [loggedSet()]),
        ]))
        let target = draft.exerciseGroups[0][0].id

        let deleted = draft.deleteExercise(id: target)
        #expect(deleted)
        #expect(draft.exerciseGroups.count == 1)
        #expect(draft.exerciseGroups[0][0].exercise.id == bench.id)
    }

    @Test("A workout emptied of every exercise says so")
    func reportsEmpty() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        draft.deleteExercise(id: draft.exerciseGroups[0][0].id)

        #expect(draft.isEmpty)
        #expect(draft.hasUnsavedChanges)
    }

    @Test("Exercise groups reorder")
    func movesGroups() {
        var draft = LoggedWorkoutDraft(loggedWorkout([
            (squat, [loggedSet()]),
            (bench, [loggedSet()]),
        ]))

        draft.moveGroup(from: 1, to: 0)
        #expect(draft.exerciseGroups[0][0].exercise.id == bench.id)
    }

    @Test("Notes on an exercise are editable")
    func editsExerciseNotes() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        let exerciseID = draft.exerciseGroups[0][0].id

        let changed = draft.updateExercise(id: exerciseID) { $0.usernotes = "belt on" }
        #expect(changed)
        #expect(draft.exercise(id: exerciseID)?.usernotes == "belt on")
    }

    // MARK: - What it refuses to touch

    /// Provenance is a fact about where a row came from. Correcting a rep count
    /// in an imported workout doesn't make it a workout logged here, and the
    /// importer matches on `source` to replace its own rows on a reload.
    @Test("Editing never disturbs provenance or the prescription snapshot")
    func leavesSourceAndPrescriptionAlone() {
        var workout = loggedWorkout()
        workout.source = "strong-csv"
        let prescription = PlannedSet(reps: 5, type: .working)
        workout.exercises?[0][0].sets?[0].plannedFrom = prescription

        var draft = LoggedWorkoutDraft(workout)
        let target = draft.workout.allSets[0].id
        draft.updateSet(id: target) { $0.reps = 4 }

        #expect(draft.workout.source == "strong-csv")
        #expect(draft.set(id: target)?.plannedFrom?.id == prescription.id)
        #expect(draft.set(id: target)?.reps == 4)
    }
}

/// `WorkoutSet.timeComplete` is the anchor anything else on the same clock —
/// a heart rate series, say — would be lined up against later. It is stored to
/// the millisecond and nothing may quietly round or drop it.
@Suite("Set completion timestamps")
struct SetTimestampTests {

    @Test("Correcting a set leaves its completion timestamp alone")
    func editingPreservesTheStamp() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        let target = draft.workout.allSets[0].id
        let stamped = later(1234.567)
        draft.updateSet(id: target) { $0.timeComplete = stamped }
        draft.markSaved()

        draft.updateSet(id: target) { $0.reps = 3 }
        draft.updateSet(id: target) { $0.weight = Measurement(value: 185, unit: .pounds) }

        #expect(draft.set(id: target)?.timeComplete == stamped)
    }

    @Test("A set added to a past workout gets no invented timestamp")
    func addedSetsAreUnstamped() {
        var draft = LoggedWorkoutDraft(loggedWorkout())
        var stamped = draft.workout.allSets[0]
        stamped.timeComplete = later(60)
        draft.updateSet(id: stamped.id) { $0.timeComplete = later(60) }

        let exerciseID = draft.exerciseGroups[0][0].id
        _ = draft.addSet(toExerciseWith: exerciseID)

        // Complete, because it happened; unstamped, because nobody knows when.
        let added = draft.exercise(id: exerciseID)?.sets?.last
        #expect(added?.complete == true)
        #expect(added?.timeComplete == nil)
    }
}

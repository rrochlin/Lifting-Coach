import Foundation
import Testing
@testable import LiftingCoachModel

private let squat = Exercise(id: 1, name: "Barbell Squat", muscleGroup: "Legs")
private let bench = Exercise(id: 2, name: "Barbell Bench Press", muscleGroup: "Chest")

private func draft(sets: Int = 3) -> PlannedWorkoutDraft {
    let exercise = PlannedExercise(
        exercise: squat,
        sets: (0..<sets).map { _ in PlannedSet(reps: 5, type: .working) },
        effort: EffortTarget(rpe: 7)
    )
    return PlannedWorkoutDraft(PlannedWorkout(date: Date(), exercises: [[exercise]]))
}

@Suite("Planned workout draft")
struct PlannedWorkoutDraftTests {

    // MARK: Save lifecycle

    @Test("A fresh draft has nothing to save")
    func freshDraftIsClean() {
        #expect(!draft().hasUnsavedChanges)
    }

    @Test("Editing marks the draft dirty; saving rebases it")
    func editThenSave() throws {
        var draft = draft()
        let set = try #require(draft.workout.allSets.first)

        draft.updateSet(id: set.id) { $0.reps = 8 }
        #expect(draft.hasUnsavedChanges)

        draft.markSaved()
        #expect(!draft.hasUnsavedChanges)
        #expect(draft.original.allSets.first?.reps == 8)
    }

    @Test("Undoing an edit by hand clears the unsaved flag")
    func editingBackToOriginalIsClean() throws {
        // The reason hasUnsavedChanges compares structurally instead of being a
        // flag each mutation sets: typing a weight and typing it back leaves
        // nothing to save, and shouldn't warn on the way out.
        var draft = draft()
        let set = try #require(draft.workout.allSets.first)

        draft.updateSet(id: set.id) { $0.reps = 8 }
        draft.updateSet(id: set.id) { $0.reps = 5 }

        #expect(!draft.hasUnsavedChanges)
    }

    @Test("Reverting throws away every edit since the last save")
    func revertDiscardsEdits() throws {
        var draft = draft()
        let set = try #require(draft.workout.allSets.first)

        draft.updateSet(id: set.id) { $0.load = .percentOf(0.8, of: .goal) }
        draft.addExercise(bench)
        draft.revert()

        #expect(!draft.hasUnsavedChanges)
        #expect(draft.workout.allSets.first?.load == nil)
        #expect(draft.exerciseGroups.count == 1)
    }

    @Test("markSaved is not called for the caller — a failed write stays dirty")
    func mutationsDoNotSelfSave() throws {
        // Guards the ordering contract: the store write happens first, and only
        // a success rebases the draft. If a mutation quietly marked itself
        // saved, a failed write would report unsaved work as saved.
        var draft = draft()
        let set = try #require(draft.workout.allSets.first)
        draft.updateSet(id: set.id) { $0.reps = 3 }
        #expect(draft.hasUnsavedChanges)
    }

    // MARK: Editing

    @Test("Adding an exercise leaves it unprescribed rather than guessing")
    func addedExerciseHasNoLoadOrEffort() throws {
        var draft = draft()
        let id = draft.addExercise(bench, sets: 4, reps: 3)

        let added = try #require(draft.exercise(id: id))
        #expect(added.sets?.count == 4)
        #expect(added.sets?.allSatisfy { $0.reps == 3 } == true)
        // An exercise just added hasn't been prescribed — a pre-filled
        // percentage would put a number in the plan nobody chose.
        #expect(added.sets?.allSatisfy { $0.load == nil } == true)
        #expect(added.effort == nil)
    }

    @Test("Adding a set copies the last set's prescription")
    func addSetCopiesShape() throws {
        var draft = draft(sets: 1)
        let exercise = try #require(draft.exerciseGroups.first?.first)
        let first = try #require(exercise.sets?.first)
        draft.updateSet(id: first.id) {
            $0.load = .percentOf(0.725, of: .goal)
            $0.reps = 2
            $0.restTime = 180
        }

        // Bound to a `let` first: #expect/#require rewrite their argument into a
        // closure that captures the value immutably, so a mutating call can't
        // appear inside one.
        let newID = draft.addSet(toExerciseWith: exercise.id)
        let added = try #require(newID.flatMap { draft.set(id: $0) })

        #expect(added.reps == 2)
        #expect(added.load == .percentOf(0.725, of: .goal))
        #expect(added.restTime == 180)
        #expect(added.id != first.id)
    }

    @Test("Deleting the last exercise in a group drops the empty group")
    func deletingLastExerciseDropsGroup() throws {
        var draft = draft()
        let exercise = try #require(draft.exerciseGroups.first?.first)

        let deleted = draft.deleteExercise(id: exercise.id)
        #expect(deleted)
        #expect(draft.exerciseGroups.isEmpty)
    }

    @Test("Deleting a set removes only that set")
    func deleteSetIsTargeted() throws {
        var draft = draft(sets: 3)
        let sets = draft.workout.allSets

        let deleted = draft.deleteSet(id: sets[1].id)
        #expect(deleted)
        #expect(draft.workout.allSets.map(\.id) == [sets[0].id, sets[2].id])
    }

    @Test("Sets reorder within their exercise")
    func moveSet() throws {
        var draft = draft(sets: 3)
        let exercise = try #require(draft.exerciseGroups.first?.first)
        let ids = draft.workout.allSets.map(\.id)

        draft.moveSet(from: 0, to: 3, within: exercise.id)

        #expect(draft.workout.allSets.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test("An out-of-range move is ignored rather than crashing")
    func moveSetOutOfRange() throws {
        var draft = draft(sets: 2)
        let exercise = try #require(draft.exerciseGroups.first?.first)
        let ids = draft.workout.allSets.map(\.id)

        draft.moveSet(from: 5, to: 0, within: exercise.id)

        #expect(draft.workout.allSets.map(\.id) == ids)
    }

    @Test("Exercise groups reorder")
    func moveGroup() throws {
        var draft = draft()
        draft.addExercise(bench)
        draft.moveGroup(from: 1, to: 0)

        #expect(draft.exerciseGroups.first?.first?.exercise.id == bench.id)
    }

    // MARK: Effort and rest

    @Test("A set with no effort of its own inherits the exercise's target")
    func effortInherits() throws {
        var draft = draft()
        let sets = draft.workout.allSets

        // "5×2 @ RPE 7" is one instruction written once on the exercise.
        #expect(draft.resolvedEffort(forSetWith: sets[0].id) == EffortTarget(rpe: 7))

        // The odd set out — a top single — overrides it.
        draft.updateSet(id: sets[2].id) { $0.effort = EffortTarget(rpe: 9) }
        #expect(draft.resolvedEffort(forSetWith: sets[2].id) == EffortTarget(rpe: 9))
        #expect(draft.resolvedEffort(forSetWith: sets[0].id) == EffortTarget(rpe: 7))
    }

    @Test("Rest is written per exercise and stored per set")
    func restAppliesToEverySet() throws {
        var draft = draft(sets: 3)
        let exercise = try #require(draft.exerciseGroups.first?.first)

        draft.setRestTime(180, forExerciseWith: exercise.id)

        #expect(draft.workout.allSets.allSatisfy { $0.restTime == 180 })
        #expect(draft.uniformRestTime(forExerciseWith: exercise.id) == 180)
    }

    @Test("A mixed rest prescription reports as mixed, not as one of its values")
    func mixedRestIsNotUniform() throws {
        var draft = draft(sets: 3)
        let exercise = try #require(draft.exerciseGroups.first?.first)
        let sets = draft.workout.allSets

        draft.setRestTime(180, forExerciseWith: exercise.id)
        draft.updateSet(id: sets[1].id) { $0.restTime = 60 }

        #expect(draft.uniformRestTime(forExerciseWith: exercise.id) == nil)
    }

    // MARK: Set grouping

    @Test("Uniform sets collapse to a single group")
    func uniformSetsCollapse() throws {
        // This is what lets a day's overview fit one line per exercise instead
        // of one per set.
        let draft = draft(sets: 5)
        let exercise = try #require(draft.exerciseGroups.first?.first)

        let groups = exercise.setGroups
        #expect(groups.count == 1)
        #expect(groups[0].count == 5)
        #expect(groups[0].reps == 5)
        // Resolved from the exercise — two sets both inheriting RPE 7 are one
        // prescription written once, not two different ones.
        #expect(groups[0].effort == EffortTarget(rpe: 7))
    }

    @Test("A changed prescription starts a new group")
    func differingSetsSplit() throws {
        var draft = draft(sets: 4)
        let sets = draft.workout.allSets
        draft.updateSet(id: sets[3].id) {
            $0.reps = 1
            $0.effort = EffortTarget(rpe: 9)
        }
        let exercise = try #require(draft.exerciseGroups.first?.first)

        let groups = exercise.setGroups
        #expect(groups.map(\.count) == [3, 1])
        #expect(groups[1].reps == 1)
        #expect(groups[1].effort == EffortTarget(rpe: 9))
    }

    @Test("Grouping is by consecutive runs, not by value")
    func groupingIsConsecutive() throws {
        // "5, 3, 5" is a different prescription from "5, 5, 3"; collapsing by
        // value alone would render them identically.
        var draft = draft(sets: 3)
        let sets = draft.workout.allSets
        draft.updateSet(id: sets[1].id) { $0.reps = 3 }
        let exercise = try #require(draft.exerciseGroups.first?.first)

        #expect(exercise.setGroups.map(\.reps) == [5, 3, 5])
    }

    @Test("An exercise with no sets has no groups")
    func noSetsNoGroups() {
        #expect(PlannedExercise(exercise: squat).setGroups.isEmpty)
    }

    @Test("An empty day label stores as nil rather than an empty string")
    func emptyNotesBecomeNil() {
        var draft = draft()
        draft.setNotes("Week 1 Mon")
        #expect(draft.workout.notes == "Week 1 Mon")

        draft.setNotes("")
        #expect(draft.workout.notes == nil)
    }
}

// MARK: - Bulk set authoring

/// "4×5 @ 225" written in one statement rather than four rows.
@Suite("Planned draft — sets × reps × weight")
struct PlannedWorkoutDraftBulkSetTests {

    private func exercise(_ sets: [PlannedSet]) -> PlannedExercise {
        PlannedExercise(
            exercise: Exercise(id: 1, name: "Barbell Squat", muscleGroup: "Quadriceps"),
            sets: sets
        )
    }

    private func draft(_ exercise: PlannedExercise) -> PlannedWorkoutDraft {
        PlannedWorkoutDraft(PlannedWorkout(exercises: [[exercise]]))
    }

    private func pounds(_ value: Double) -> LoadPrescription {
        .absolute(Measurement(value: value, unit: .pounds))
    }

    @Test("Writes the whole prescription at once")
    func writesEveryWorkingSet() {
        var draft = draft(exercise([PlannedSet(reps: 8, type: .working)]))
        let id = draft.workout.exercises![0][0].id

        draft.setWorkingSets(count: 4, reps: 5, load: pounds(225), toExerciseWith: id)

        let sets = draft.workout.exercises![0][0].sets ?? []
        #expect(sets.count == 4)
        #expect(sets.allSatisfy { $0.reps == 5 })
        #expect(sets.allSatisfy { $0.load == pounds(225) })
    }

    @Test("Warmups and drops are left exactly where they were")
    func leavesOtherTypesAlone() {
        var draft = draft(exercise([
            PlannedSet(reps: 5, type: .warmup),
            PlannedSet(reps: 8, type: .working),
            PlannedSet(reps: 12, type: .drop),
        ]))
        let id = draft.workout.exercises![0][0].id

        draft.setWorkingSets(count: 3, reps: 5, load: pounds(225), toExerciseWith: id)

        let sets = draft.workout.exercises![0][0].sets ?? []
        // Warmup first, three working, drop last — a bulk prescription is never
        // an instruction to delete a ramp.
        #expect(sets.map { $0.type ?? .working } == [.warmup, .working, .working, .working, .drop])
        #expect(sets.first?.reps == 5)
        #expect(sets.last?.reps == 12)
        #expect(sets.last?.type == .drop)
    }

    @Test("Growing keeps the sets that already existed")
    func growingPreservesIdentity() {
        var draft = draft(exercise([
            PlannedSet(reps: 5, type: .working, effort: EffortTarget(rpe: 7)),
            PlannedSet(reps: 5, type: .working),
        ]))
        let id = draft.workout.exercises![0][0].id
        let firstID = draft.workout.exercises![0][0].sets![0].id

        draft.setWorkingSets(count: 4, reps: 3, load: pounds(315), toExerciseWith: id)

        let sets = draft.workout.exercises![0][0].sets ?? []
        #expect(sets.count == 4)
        #expect(sets[0].id == firstID)
        // A per-set RPE the author wrote survives a change of reps and weight.
        #expect(sets[0].effort?.rpe == 7)
        // New sets inherit it, which is what "a fourth set of the same thing"
        // means.
        #expect(sets[3].effort?.rpe == 7)
    }

    @Test("Trimming removes from the end")
    func trimmingDropsTheLast() {
        var draft = draft(exercise([
            PlannedSet(reps: 5, type: .working),
            PlannedSet(reps: 5, type: .working),
            PlannedSet(reps: 5, type: .working),
        ]))
        let id = draft.workout.exercises![0][0].id
        let firstID = draft.workout.exercises![0][0].sets![0].id

        draft.setWorkingSets(count: 1, reps: 5, load: nil, toExerciseWith: id)

        let sets = draft.workout.exercises![0][0].sets ?? []
        #expect(sets.count == 1)
        #expect(sets[0].id == firstID)
    }

    @Test("An exercise with no working sets gains them after its warmups")
    func addsToAWarmupOnlyExercise() {
        var draft = draft(exercise([PlannedSet(reps: 5, type: .warmup)]))
        let id = draft.workout.exercises![0][0].id

        draft.setWorkingSets(count: 2, reps: 5, load: pounds(135), toExerciseWith: id)

        let sets = draft.workout.exercises![0][0].sets ?? []
        #expect(sets.map { $0.type ?? .working } == [.warmup, .working, .working])
    }

    @Test("Zero working sets is a legal thing to write")
    func zeroClearsWorkingSets() {
        var draft = draft(exercise([
            PlannedSet(reps: 5, type: .warmup),
            PlannedSet(reps: 5, type: .working),
        ]))
        let id = draft.workout.exercises![0][0].id

        draft.setWorkingSets(count: 0, reps: 5, load: nil, toExerciseWith: id)

        let sets = draft.workout.exercises![0][0].sets ?? []
        #expect(sets.map { $0.type ?? .working } == [.warmup])
    }
}

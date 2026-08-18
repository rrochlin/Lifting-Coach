import Foundation
import Testing
@testable import LiftingCoachModel

private let squat = ExerciseCatalog.seed[0]
private let bench = ExerciseCatalog.seed[1]
private let row = ExerciseCatalog.seed[4]

private let noon = Date(timeIntervalSince1970: 1_770_000_000)
private func later(_ seconds: TimeInterval) -> Date { noon.addingTimeInterval(seconds) }

private func plannedWorkout(
    _ exercises: [(Exercise, [PlannedSet])]
) -> PlannedWorkout {
    PlannedWorkout(
        exercises: exercises.map { [PlannedExercise(exercise: $0.0, sets: $0.1)] }
    )
}

@Suite("Starting a session from a plan")
struct WorkoutSessionStartTests {

    @Test("Prescribed sets become logged sets that remember their prescription")
    func materializesFromPlan() {
        let prescribed = PlannedSet(reps: 5, type: .working, load: .absolute(Measurement(value: 225, unit: .pounds)))
        let session = WorkoutSession.start(from: plannedWorkout([(squat, [prescribed])]), at: noon)

        let logged = session.workout.allSets
        #expect(logged.count == 1)
        #expect(logged[0].reps == 5)
        #expect(logged[0].weight?.value == 225)
        #expect(logged[0].complete == false)
        #expect(logged[0].plannedFrom?.id == prescribed.id)
        #expect(session.workout.startTime == noon)
    }

    @Test("A goal-percentage prescription resolves against the goal max")
    func resolvesPercentOfMax() {
        let user = User(
            name: "Rob",
            email: "r@example.com",
            goalMaxes: [bench.id: GoalMax(weight: Measurement(value: 300, unit: .pounds))]
        )
        let session = WorkoutSession.start(
            from: plannedWorkout([(bench, [PlannedSet(reps: 3, load: .percentOf(0.9, of: .goal))])]),
            user: user,
            at: noon
        )

        #expect(session.workout.allSets.first?.weight?.value == 270)
    }

    @Test("An effort-only prescription leaves the weight unset")
    func effortOnlyLeavesWeightBlank() {
        // "3x8 @ RPE 8, pick your weight" — a legitimate prescription with no
        // load axis at all. The effort stays visible; the lifter supplies the
        // number.
        let session = WorkoutSession.start(
            from: plannedWorkout([(bench, [PlannedSet(reps: 8, effort: EffortTarget(rpe: 8))])]),
            user: User(name: "Rob", email: "r@example.com"),
            at: noon
        )

        let set = session.workout.allSets.first
        #expect(set?.weight == nil)
        #expect(set?.plannedFrom?.effort == EffortTarget(rpe: 8))
    }

    @Test("Exercise-level effort is materialized into each set's snapshot")
    func materializesExerciseEffort() {
        // "5x2 @ RPE 7" is one instruction on the exercise. History keeps only
        // the per-set snapshot, so the resolved target must be baked in at start.
        let override = PlannedSet(reps: 1, effort: EffortTarget(rpe: 9))
        let planned = PlannedWorkout(exercises: [[
            PlannedExercise(
                exercise: squat,
                sets: [PlannedSet(reps: 2), PlannedSet(reps: 2), override],
                effort: EffortTarget(rpe: 7)
            )
        ]])

        let session = WorkoutSession.start(from: planned, at: noon)
        let snapshots = session.workout.allSets.map(\.plannedFrom)

        #expect(snapshots[0]?.effort == EffortTarget(rpe: 7))
        #expect(snapshots[1]?.effort == EffortTarget(rpe: 7))
        // the per-set override wins over the exercise target
        #expect(snapshots[2]?.effort == EffortTarget(rpe: 9))
    }

    @Test("An absolute prescription resolves with no lifter on file")
    func absoluteNeedsNoUser() {
        // Regression: absolute loads were briefly gated behind an optional User,
        // so following a plan before recording any 1RM silently dropped every
        // prescribed weight.
        let session = WorkoutSession.start(
            from: plannedWorkout([(squat, [PlannedSet(reps: 5, load: .absolute(Measurement(value: 315, unit: .pounds)))])]),
            user: nil,
            at: noon
        )

        #expect(session.workout.allSets.first?.weight?.value == 315)
    }

    @Test("Supersets survive materialization as a single group")
    func preservesSupersetGrouping() {
        let planned = PlannedWorkout(exercises: [
            [
                PlannedExercise(exercise: bench, sets: [PlannedSet(reps: 8)]),
                PlannedExercise(exercise: row, sets: [PlannedSet(reps: 8)]),
            ]
        ])

        let session = WorkoutSession.start(from: planned, at: noon)
        #expect(session.exerciseGroups.count == 1)
        #expect(session.exerciseGroups[0].count == 2)
    }
}

@Suite("Logging sets")
struct WorkoutSessionLoggingTests {

    private func session() -> WorkoutSession {
        WorkoutSession.start(
            from: plannedWorkout([(squat, [
                PlannedSet(reps: 5, type: .working, load: .absolute(Measurement(value: 225, unit: .pounds))),
                PlannedSet(reps: 5, type: .working, load: .absolute(Measurement(value: 225, unit: .pounds))),
            ])]),
            at: noon
        )
    }

    @Test("Checking off an as-prescribed set needs no arguments")
    func completeWithoutOverrides() {
        var session = self.session()
        let first = session.workout.allSets[0]

        let didComplete = session.completeSet(id: first.id, at: later(60))
        #expect(didComplete)

        let logged = session.workout.allSets[0]
        #expect(logged.complete == true)
        #expect(logged.timeComplete == later(60))
        #expect(logged.reps == 5)
        #expect(logged.weight?.value == 225)
    }

    @Test("Overrides record what was actually lifted")
    func completeWithOverrides() {
        var session = self.session()
        let first = session.workout.allSets[0]

        session.completeSet(
            id: first.id,
            reps: 3,
            weight: Measurement(value: 245, unit: .pounds),
            rpe: 9.5,
            at: later(60)
        )

        let logged = session.workout.allSets[0]
        #expect(logged.reps == 3)
        #expect(logged.weight?.value == 245)
        #expect(logged.rpe == 9.5)
    }

    @Test("Rest actually taken is not inferred from completion timestamps")
    func doesNotMeasureRestBetweenSets() {
        var session = self.session()
        let sets = session.workout.allSets

        session.completeSet(id: sets[0].id, at: later(60))
        session.completeSet(id: sets[1].id, at: later(60 + 180))

        // The gap between two completions is rest *plus* however long it took to
        // reach for the phone, so it's not rest — and it's biased long every
        // time. Logging it would look like a measurement it isn't.
        #expect(session.workout.allSets[0].restTime == nil)
        #expect(session.workout.allSets[1].restTime == nil)
    }

    @Test("Un-completing clears the timestamp but keeps the numbers")
    func uncompletePreservesEntry() {
        var session = self.session()
        let first = session.workout.allSets[0]
        session.completeSet(id: first.id, reps: 3, rpe: 9, at: later(60))

        let didUncomplete = session.uncompleteSet(id: first.id)
        #expect(didUncomplete)

        let set = session.workout.allSets[0]
        #expect(set.complete == false)
        #expect(set.timeComplete == nil)
        #expect(set.restTime == nil)
        // Un-checking a set is a correction to its status, not to its contents.
        #expect(set.reps == 3)
        #expect(set.rpe == 9)
    }

    @Test("Un-completing leaves the rest prescription alone")
    func uncompleteKeepsRestSane() {
        var session = self.session()
        let sets = session.workout.allSets
        session.completeSet(id: sets[0].id, at: later(60))
        session.uncompleteSet(id: sets[0].id)

        session.completeSet(id: sets[1].id, at: later(300))

        // Rest owed comes from the prescription, not from set status, so
        // un-checking a set can't change what the next set's timer counts.
        #expect(session.workout.allSets[1].restTime == nil)
        #expect(session.restTarget(afterSetWith: sets[1].id) == 120)
    }

    @Test("Completing an unknown set id reports failure")
    func unknownSetIsRejected() {
        var session = self.session()
        let didComplete = session.completeSet(id: UUID(), at: noon)
        #expect(!didComplete)
    }
}

@Suite("Session cursor and progress")
struct WorkoutSessionCursorTests {

    private func session() -> WorkoutSession {
        WorkoutSession.start(
            from: plannedWorkout([
                (squat, [PlannedSet(reps: 5), PlannedSet(reps: 5)]),
                (bench, [PlannedSet(reps: 8)]),
            ]),
            at: noon
        )
    }

    @Test("The active exercise holds the first unchecked set")
    func tracksActiveExercise() {
        var session = self.session()
        #expect(session.activeExercise == ExerciseAddress(group: 0, index: 0))

        let squatSets = session.exerciseGroups[0][0].sets!
        session.completeSet(id: squatSets[0].id, at: later(60))
        #expect(session.activeExercise == ExerciseAddress(group: 0, index: 0))

        session.completeSet(id: squatSets[1].id, at: later(120))
        #expect(session.activeExercise == ExerciseAddress(group: 1, index: 0))
    }

    @Test("There is no active exercise once everything is checked off")
    func noActiveExerciseWhenDone() {
        var session = self.session()
        for set in session.workout.allSets {
            session.completeSet(id: set.id, at: later(60))
        }

        #expect(session.activeExercise == nil)
        #expect(session.nextSet == nil)
        #expect(session.isComplete)
    }

    @Test("Progress counts completed against total")
    func reportsProgress() {
        var session = self.session()
        #expect(session.progress == (completed: 0, total: 3))

        session.completeSet(id: session.workout.allSets[0].id, at: later(60))
        #expect(session.progress == (completed: 1, total: 3))
    }

    @Test("An empty workout is not complete")
    func emptyIsNotComplete() {
        // Guards the `allSatisfy` trap: an empty collection satisfies everything.
        #expect(!WorkoutSession.adHoc(at: noon).isComplete)
    }
}

@Suite("Rest targets")
struct WorkoutSessionRestTests {

    @Test("Rest target falls back set → block → app default")
    func restTargetFallback() {
        let block = WorkoutBlock(defaultRestTimes: [.working: 180])
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, [
                PlannedSet(reps: 5, type: .working, restTime: 300),
                PlannedSet(reps: 5, type: .working),
                PlannedSet(reps: 10, type: .drop),
            ])]),
            block: block,
            at: noon,
            appDefaultRestTime: 90
        )

        let sets = session.workout.allSets
        #expect(session.restTarget(afterSetWith: sets[0].id) == 300)
        #expect(session.restTarget(afterSetWith: sets[1].id) == 180)
        #expect(session.restTarget(afterSetWith: sets[2].id) == 90)

        // A set added mid-workout has no prescription, so it falls through to
        // its set type. It copies the last set's type — .drop here, which this
        // block has no default for — so it lands on the app default.
        let added = session.addSet(toExerciseWith: session.exerciseGroups[0][0].id)!
        #expect(session.restTarget(afterSetWith: added) == 90)
    }

    @Test("An unprescribed set of a type the block does define uses the block default")
    func addedSetUsesBlockDefaultForItsType() {
        let block = WorkoutBlock(defaultRestTimes: [.working: 180])
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, [PlannedSet(reps: 5, type: .working)])]),
            block: block,
            at: noon,
            appDefaultRestTime: 90
        )

        let added = session.addSet(toExerciseWith: session.exerciseGroups[0][0].id)!
        #expect(session.restTarget(afterSetWith: added) == 180)
    }

    @Test("The lifter's own rest for a set beats every level of the prescription")
    func overrideOutranksPrescription() {
        let block = WorkoutBlock(defaultRestTimes: [.working: 180])
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, [PlannedSet(reps: 5, type: .working, restTime: 300)])]),
            block: block,
            at: noon,
            appDefaultRestTime: 90
        )

        let setID = session.workout.allSets[0].id
        #expect(session.restTarget(afterSetWith: setID) == 300)

        session.setRest(210, forSetWith: setID)
        #expect(session.restTarget(afterSetWith: setID) == 210)
        // The prescription is untouched underneath, so "back to what the
        // program said" stays answerable.
        #expect(session.prescribedRest(afterSetWith: setID) == 300)
        #expect(session.workout.allSets[0].plannedFrom?.restTime == 300)
    }

    @Test("Clearing the override falls back to the prescription again")
    func clearingOverrideRestoresPrescription() {
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, [PlannedSet(reps: 5, type: .working, restTime: 240)])]),
            at: noon
        )

        let setID = session.workout.allSets[0].id
        session.setRest(60, forSetWith: setID)
        session.setRest(nil, forSetWith: setID)

        #expect(session.workout.allSets[0].restOverride == nil)
        #expect(session.restTarget(afterSetWith: setID) == 240)
    }

    @Test("No rest is a legitimate answer; negative rest isn't")
    func overrideClampsAtZero() {
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, [PlannedSet(reps: 5, type: .working, restTime: 240)])]),
            at: noon
        )

        let setID = session.workout.allSets[0].id
        session.setRest(0, forSetWith: setID)
        // Zero has to stick rather than reading as "unset" — a superset's first
        // movement legitimately rests for nothing.
        #expect(session.restTarget(afterSetWith: setID) == 0)

        session.setRest(-30, forSetWith: setID)
        #expect(session.restTarget(afterSetWith: setID) == 0)
    }

    @Test("A set added after tuning rest inherits the tuned value")
    func addedSetCopiesTunedRest() {
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, [PlannedSet(reps: 5, type: .working, restTime: 240)])]),
            at: noon
        )

        session.setRest(150, forSetWith: session.workout.allSets[0].id)
        let added = session.addSet(toExerciseWith: session.exerciseGroups[0][0].id)!

        // Unlike `plannedFrom`, which is deliberately dropped: the tuning is the
        // lifter's instruction for this lift today, and re-entering it on every
        // added set is the friction the control exists to remove.
        #expect(session.restTarget(afterSetWith: added) == 150)
    }
}

@Suite("Editing mid-workout")
struct WorkoutSessionEditingTests {

    private func session() -> WorkoutSession {
        WorkoutSession.start(
            from: plannedWorkout([
                (squat, [PlannedSet(reps: 5, type: .working, load: .absolute(Measurement(value: 225, unit: .pounds)))]),
                (bench, [PlannedSet(reps: 8)]),
            ]),
            at: noon
        )
    }

    @Test("An added set copies the previous set's shape but not its prescription")
    func addedSetIsUnprescribed() {
        var session = self.session()
        let exerciseID = session.exerciseGroups[0][0].id

        let newID = session.addSet(toExerciseWith: exerciseID)
        let added = session.workout.allSets.first { $0.id == newID }

        #expect(added?.reps == 5)
        #expect(added?.weight?.value == 225)
        #expect(added?.complete == false)
        // Counting an unprescribed set as prescribed would inflate adherence.
        #expect(added?.plannedFrom == nil)
    }

    @Test("A warmup set goes in front of the prescription, empty and typed")
    func warmupSetIsPrependedAndEmpty() {
        var session = self.session()
        let exerciseID = session.exerciseGroups[0][0].id

        let newID = session.addWarmupSet(toExerciseWith: exerciseID)
        let sets = session.exerciseGroups[0][0].sets ?? []

        #expect(sets.count == 2)
        // In front: a ramp-up leads to the working set, it doesn't follow it.
        #expect(sets.first?.id == newID)
        #expect(sets.first?.type == .warmup)
        // Empty, not a copy — a warmup is lighter than the set it precedes, so
        // pre-filling 225 would mean clearing it every time.
        #expect(sets.first?.reps == nil)
        #expect(sets.first?.weight == nil)
        #expect(sets.first?.plannedFrom == nil)
        // The prescribed set is untouched and still second.
        #expect(sets.last?.reps == 5)
    }

    @Test("A warmup set is never an achieved max")
    func warmupSetDoesNotRecordMax() {
        var session = self.session()
        let exerciseID = session.exerciseGroups[0][0].id
        let newID = session.addWarmupSet(toExerciseWith: exerciseID)!

        session.completeSet(
            id: newID,
            reps: 1,
            weight: Measurement(value: 405, unit: .pounds),
            at: noon
        )
        let warmup = session.workout.allSets.first { $0.id == newID }!

        #expect(AchievedMaxUpdate.evaluate(set: warmup, for: squat, currentBest: nil) == nil)
    }

    @Test("Sets and exercises can be removed")
    func removesSetsAndExercises() {
        var session = self.session()
        let benchExerciseID = session.exerciseGroups[1][0].id
        let squatSetID = session.exerciseGroups[0][0].sets![0].id

        let didDeleteSet = session.deleteSet(id: squatSetID)
        #expect(didDeleteSet)
        #expect(session.exerciseGroups[0][0].sets?.isEmpty == true)

        let didDeleteExercise = session.deleteExercise(id: benchExerciseID)
        #expect(didDeleteExercise)
        #expect(session.exerciseGroups.count == 1)
    }

    @Test("Removing the last exercise in a superset drops the empty group")
    func dropsEmptiedGroup() {
        var session = WorkoutSession.start(
            from: PlannedWorkout(exercises: [[
                PlannedExercise(exercise: bench, sets: [PlannedSet(reps: 8)]),
                PlannedExercise(exercise: row, sets: [PlannedSet(reps: 8)]),
            ]]),
            at: noon
        )

        session.deleteExercise(id: session.exerciseGroups[0][0].id)
        #expect(session.exerciseGroups.count == 1)
        #expect(session.exerciseGroups[0].count == 1)

        session.deleteExercise(id: session.exerciseGroups[0][0].id)
        #expect(session.exerciseGroups.isEmpty)
    }

    @Test("An ad-hoc exercise can be added with empty sets")
    func addsExercise() {
        var session = WorkoutSession.adHoc(at: noon)
        let id = session.addExercise(row, sets: 3)

        #expect(session.exerciseGroups.count == 1)
        #expect(session.exerciseGroups[0][0].id == id)
        #expect(session.workout.allSets.count == 3)
    }

    @Test("Groups reorder correctly in both directions")
    func reordersGroups() {
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, []), (bench, []), (row, [])]),
            at: noon
        )
        func order(_ s: WorkoutSession) -> [String] {
            s.exerciseGroups.map(\.first!.exercise.name)
        }

        // Moving later: the target index must account for the removal shift, or
        // the group lands one slot too far along.
        session.moveGroup(from: 0, to: 2)
        #expect(order(session) == ["Bench Press", "Back Squat", "Barbell Row"])

        session.moveGroup(from: 2, to: 0)
        #expect(order(session) == ["Barbell Row", "Bench Press", "Back Squat"])
    }

    @Test("Out-of-range reorders are ignored rather than crashing")
    func reorderBoundsAreSafe() {
        var session = self.session()
        let before = session.exerciseGroups.count

        session.moveGroup(from: 9, to: 0)
        session.moveGroup(from: 0, to: -1)
        session.moveGroup(from: 0, to: 0)

        #expect(session.exerciseGroups.count == before)
    }

    @Test("Sets reorder correctly in both directions")
    func reordersSets() {
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, [
                PlannedSet(reps: 5, load: .absolute(Measurement(value: 135, unit: .pounds))),
                PlannedSet(reps: 3, load: .absolute(Measurement(value: 225, unit: .pounds))),
                PlannedSet(reps: 1, load: .absolute(Measurement(value: 315, unit: .pounds))),
            ])]),
            at: noon
        )
        let exerciseID = session.exerciseGroups[0][0].id
        func order(_ s: WorkoutSession) -> [Double] {
            s.exerciseGroups[0][0].sets!.map { $0.weight!.value }
        }

        // Same shift-adjustment semantics as moveGroup: removing index 0 then
        // inserting at the shifted index 1 lands the moved set second, not last.
        session.moveSet(from: 0, to: 2, within: exerciseID)
        #expect(order(session) == [225, 135, 315])

        session.moveSet(from: 2, to: 0, within: exerciseID)
        #expect(order(session) == [315, 225, 135])
    }

    @Test("Out-of-range set reorders are ignored rather than crashing")
    func setReorderBoundsAreSafe() {
        var session = self.session()
        let exerciseID = session.exerciseGroups[0][0].id
        let before = session.exerciseGroups[0][0].sets?.count

        session.moveSet(from: 9, to: 0, within: exerciseID)
        session.moveSet(from: 0, to: -1, within: exerciseID)
        session.moveSet(from: 0, to: 0, within: exerciseID)
        // An unknown exercise id is also a no-op, not a crash.
        session.moveSet(from: 0, to: 0, within: UUID())

        #expect(session.exerciseGroups[0][0].sets?.count == before)
    }

    @Test("moveSet only reorders its target exercise's own sets")
    func moveSetIsScopedToItsExercise() {
        var session = self.session()
        let squatID = session.exerciseGroups[0][0].id
        let benchSetsBefore = session.exerciseGroups[1][0].sets

        // Squat has only one set, so this is a no-op move, but it must not
        // touch bench's sets either way.
        session.moveSet(from: 0, to: 0, within: squatID)

        #expect(session.exerciseGroups[1][0].sets == benchSetsBefore)
    }

    @Test("updateExercise mutates notes and reports whether it found the exercise")
    func updateExerciseMutatesNotes() {
        var session = self.session()
        let exerciseID = session.exerciseGroups[0][0].id

        let didUpdate = session.updateExercise(id: exerciseID) { $0.usernotes = "felt heavy today" }
        #expect(didUpdate)
        #expect(session.exerciseGroups[0][0].usernotes == "felt heavy today")

        let didUpdateUnknown = session.updateExercise(id: UUID()) { $0.usernotes = "x" }
        #expect(!didUpdateUnknown)
    }
}

@Suite("Finishing")
struct WorkoutSessionFinishTests {

    @Test("Unfinished sets are dropped rather than logged as zeroes")
    func discardsIncompleteSets() {
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, [PlannedSet(reps: 5), PlannedSet(reps: 5), PlannedSet(reps: 5)])]),
            at: noon
        )
        session.completeSet(id: session.workout.allSets[0].id, at: later(60))

        session.finish(at: later(3600))

        // Keeping skipped sets would drag down every volume and adherence figure
        // computed from this workout later.
        #expect(session.workout.allSets.count == 1)
        #expect(session.workout.endTime == later(3600))
        #expect(!session.workout.isInProgress)
    }

    @Test("An exercise left entirely undone is dropped with its sets")
    func dropsUntouchedExercises() {
        var session = WorkoutSession.start(
            from: plannedWorkout([(squat, [PlannedSet(reps: 5)]), (bench, [PlannedSet(reps: 8)])]),
            at: noon
        )
        session.completeSet(id: session.exerciseGroups[0][0].sets![0].id, at: later(60))

        session.finish(at: later(3600))

        #expect(session.exerciseGroups.count == 1)
        #expect(session.exerciseGroups[0][0].exercise.id == squat.id)
    }
}

import Foundation
import Testing
@testable import LiftingCoachModel

private let noon = Date(timeIntervalSince1970: 1_770_000_000)

private func workingSet(_ weight: Double, reps: Int = 1, complete: Bool = true) -> WorkoutSet {
    WorkoutSet(
        reps: reps,
        weight: Measurement(value: weight, unit: .pounds),
        complete: complete,
        type: .working,
        timeComplete: complete ? noon : nil
    )
}

private let specificExercise = Exercise(id: 1, name: "Barbell Bench Press", muscleGroup: "Chest")
private let openChoiceExercise = Exercise(
    id: 2, name: "Triceps (overhead ext / pushdown)", muscleGroup: "Triceps", isOpenChoice: true
)

@Suite("Achieved max update")
struct AchievedMaxUpdateTests {

    @Test("A heavier weight becomes the new max regardless of reps")
    func heavierWeightWins() {
        let currentBest = AchievedMax(weight: Measurement(value: 325, unit: .pounds), date: .distantPast)

        // 335x3 sets an achieved max of 335, not a projected higher single —
        // reps don't inflate the recorded weight.
        let update = AchievedMaxUpdate.evaluate(set: workingSet(335, reps: 3), for: specificExercise, currentBest: currentBest)
        #expect(update?.weight.value == 335)
    }

    @Test("No prior max — any completed working set becomes the max")
    func noCurrentBest() {
        let update = AchievedMaxUpdate.evaluate(set: workingSet(335), for: specificExercise, currentBest: nil)
        #expect(update?.weight.value == 335)
    }

    @Test("A lighter or equal weight is not a new max")
    func lighterWeightIsNotNew() {
        let currentBest = AchievedMax(weight: Measurement(value: 335, unit: .pounds), date: .distantPast)

        #expect(AchievedMaxUpdate.evaluate(set: workingSet(315), for: specificExercise, currentBest: currentBest) == nil)
        #expect(AchievedMaxUpdate.evaluate(set: workingSet(335), for: specificExercise, currentBest: currentBest) == nil)
    }

    @Test("Comparison converts units — a heavier kg set beats a lb max")
    func comparesAcrossUnits() {
        let currentBest = AchievedMax(weight: Measurement(value: 300, unit: .pounds), date: .distantPast)
        let heavierInKg = WorkoutSet(
            reps: 1, weight: Measurement(value: 145, unit: .kilograms),
            complete: true, type: .working, timeComplete: noon
        )

        // 145 kg ≈ 319.7 lb — heavier than the 300 lb best.
        let update = AchievedMaxUpdate.evaluate(set: heavierInKg, for: specificExercise, currentBest: currentBest)
        #expect(update?.weight.value == 145)
        #expect(update?.weight.unit == UnitMass.kilograms)
    }

    @Test("Warmups and drop sets never count, no matter the weight")
    func nonWorkingSetsAreIgnored() {
        let warmup = WorkoutSet(reps: 1, weight: Measurement(value: 500, unit: .pounds), complete: true, type: .warmup)
        let drop = WorkoutSet(reps: 1, weight: Measurement(value: 500, unit: .pounds), complete: true, type: .drop)

        #expect(AchievedMaxUpdate.evaluate(set: warmup, for: specificExercise, currentBest: nil) == nil)
        #expect(AchievedMaxUpdate.evaluate(set: drop, for: specificExercise, currentBest: nil) == nil)
    }

    @Test("An incomplete or weightless set never counts")
    func incompleteOrWeightlessIsIgnored() {
        let incomplete = WorkoutSet(reps: 1, weight: Measurement(value: 500, unit: .pounds), complete: false, type: .working)
        let noWeight = WorkoutSet(reps: 1, weight: nil, complete: true, type: .working)

        #expect(AchievedMaxUpdate.evaluate(set: incomplete, for: specificExercise, currentBest: nil) == nil)
        #expect(AchievedMaxUpdate.evaluate(set: noWeight, for: specificExercise, currentBest: nil) == nil)
    }

    @Test("The recorded date defaults to when the set was completed")
    func defaultsDateToCompletion() {
        let update = AchievedMaxUpdate.evaluate(set: workingSet(335), for: specificExercise, currentBest: nil)
        #expect(update?.date == noon)
    }

    @Test("An open-choice exercise never records a max, however heavy")
    func openChoiceExerciseNeverRecordsAMax() {
        // "Triceps (overhead ext / pushdown)" — a heavier weight this week
        // than last doesn't mean progress on the same lift; it might not be
        // the same lift at all (Exercise.isOpenChoice).
        #expect(AchievedMaxUpdate.evaluate(set: workingSet(50), for: openChoiceExercise, currentBest: nil) == nil)

        let currentBest = AchievedMax(weight: Measurement(value: 30, unit: .pounds), date: .distantPast)
        #expect(AchievedMaxUpdate.evaluate(set: workingSet(100), for: openChoiceExercise, currentBest: currentBest) == nil)
    }
}

@Suite("WorkoutSession.exercise(containingSetID:)")
struct WorkoutSessionSetLookupTests {

    @Test("Finds the exercise across superset groups")
    func findsAcrossGroups() {
        let squat = ExerciseCatalog.seed[0]
        let bench = ExerciseCatalog.seed[1]
        let targetSet = WorkoutSet(reps: 8)
        let session = WorkoutSession(workout: Workout(exercises: [
            [WorkoutExercise(exercise: squat, sets: [WorkoutSet(reps: 5)])],
            [WorkoutExercise(exercise: bench, sets: [targetSet])],
        ]))

        #expect(session.exercise(containingSetID: targetSet.id)?.exercise.id == bench.id)
    }

    @Test("Returns nil for an unknown set id")
    func unknownIDReturnsNil() {
        let session = WorkoutSession.adHoc()
        #expect(session.exercise(containingSetID: UUID()) == nil)
    }
}

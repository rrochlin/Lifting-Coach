import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func makeStore() throws -> (UserStore, User) {
    let database = try AppDatabase.inMemory()
    try ExerciseStore(database).save(ExerciseCatalog.seed)
    let users = UserStore(database, calendar: calendar)
    return (users, try users.localUser())
}

@Suite("Unit preference")
struct UnitPreferenceTests {

    @Test("A new lifter reads weights in pounds")
    func defaultsToPounds() throws {
        let (_, user) = try makeStore()
        #expect(user.preferredUnit == .pounds)
    }

    @Test("The unit preference survives a round trip")
    func preferredUnitRoundTrips() throws {
        let (users, user) = try makeStore()

        try users.setPreferredUnit(.kilograms, for: user.id)

        #expect(try users.fetch(id: user.id)?.preferredUnit == .kilograms)
        #expect(try users.localUser().preferredUnit == .kilograms)
    }

    @Test("Switching units rewrites nothing that was already logged")
    func switchingUnitsLeavesHistoryAlone() throws {
        let (users, user) = try makeStore()
        let squat = ExerciseCatalog.seed[0]
        try users.recordBodyWeight(Measurement(value: 198.4, unit: .pounds), for: user.id)
        try users.recordAchievedMax(
            AchievedMax(weight: Measurement(value: 455, unit: .pounds), date: Date()),
            exerciseId: squat.id,
            for: user.id
        )

        try users.setPreferredUnit(.kilograms, for: user.id)

        // The whole claim the Profile screen makes to the lifter: this is a
        // reading preference, not a conversion of their training history. The
        // pounds are still pounds on disk; the app converts on the way out.
        let reloaded = try #require(try users.fetch(id: user.id))
        #expect(reloaded.currentBodyWeight == Measurement(value: 198.4, unit: .pounds))
        #expect(reloaded.max(.achieved, for: squat.id) == Measurement(value: 455, unit: .pounds))
        #expect(reloaded.preferredUnit == .kilograms)
    }

    @Test("Saving the whole lifter carries the preference with it")
    func savePersistsPreference() throws {
        let (users, user) = try makeStore()

        var edited = user
        edited.preferredUnit = .kilograms
        edited.name = "Rob"
        try users.save(edited)

        let reloaded = try #require(try users.fetch(id: user.id))
        #expect(reloaded.preferredUnit == .kilograms)
        #expect(reloaded.name == "Rob")
    }
}

@Suite("Per-exercise unit preference")
struct ExerciseUnitPreferenceTests {

    /// The seed catalog's first entry, whatever it is — these tests care about
    /// the preference, not about which lift carries it.
    private func anyExerciseID() -> Int { ExerciseCatalog.seed[0].id }

    @Test("An exercise with no preference of its own reads in the app default")
    func fallsThroughToAppDefault() throws {
        let (_, user) = try makeStore()
        #expect(user.unit(forExerciseID: anyExerciseID()) == .pounds)
    }

    @Test("A pinned lift overrides the app default, and only for that lift")
    func exerciseUnitOverridesAppDefault() throws {
        let (users, user) = try makeStore()
        let pinned = anyExerciseID()
        let other = ExerciseCatalog.seed[1].id

        try users.setUnit(.kilograms, forExerciseID: pinned, for: user.id)

        let reloaded = try #require(try users.fetch(id: user.id))
        #expect(reloaded.unit(forExerciseID: pinned) == .kilograms)
        // The whole point of a per-lift preference is that it doesn't leak.
        #expect(reloaded.unit(forExerciseID: other) == .pounds)
        #expect(reloaded.preferredUnit == .pounds)
    }

    @Test("Clearing a pinned lift falls back to the app default again")
    func clearingRestoresFallback() throws {
        let (users, user) = try makeStore()
        let pinned = anyExerciseID()

        try users.setUnit(.kilograms, forExerciseID: pinned, for: user.id)
        try users.setUnit(nil, forExerciseID: pinned, for: user.id)

        let reloaded = try #require(try users.fetch(id: user.id))
        #expect(reloaded.unit(forExerciseID: pinned) == .pounds)
        #expect(reloaded.exerciseUnits?[pinned] == nil)
    }

    @Test("Pinning the same lift twice replaces rather than duplicating")
    func repinReplaces() throws {
        let (users, user) = try makeStore()
        let pinned = anyExerciseID()

        try users.setUnit(.kilograms, forExerciseID: pinned, for: user.id)
        try users.setUnit(.pounds, forExerciseID: pinned, for: user.id)

        let reloaded = try #require(try users.fetch(id: user.id))
        #expect(reloaded.exerciseUnits?[pinned] == .pounds)
    }

    @Test("A pinned lift changes what's read, never what's stored")
    func pinningRewritesNothing() throws {
        let database = try AppDatabase.inMemory()
        try ExerciseStore(database).save(ExerciseCatalog.seed)
        let users = UserStore(database, calendar: calendar)
        let user = try users.localUser()
        let workouts = WorkoutStore(database, calendar: calendar)
        let exercise = ExerciseCatalog.seed[0]

        let logged = Measurement(value: 225, unit: UnitMass.pounds)
        try workouts.save(
            Workout(
                exercises: [[WorkoutExercise(
                    exercise: exercise,
                    sets: [WorkoutSet(reps: 5, weight: logged, complete: true, type: .working)]
                )]],
                startTime: Date(),
                endTime: Date()
            )
        )

        try users.setUnit(.kilograms, forExerciseID: exercise.id, for: user.id)

        // The row on disk is untouched — same value, same unit. Switching a
        // unit is a reading decision; converting the table would round every
        // historical row and make a display choice destructive.
        let stored = try #require(try workouts.fetch(from: .distantPast, to: .distantFuture).first)
        let set = try #require(stored.allSets.first)
        #expect(set.weight?.value == 225)
        #expect(set.weight?.unit == .pounds)
        // And the same weight read under the preference is the same iron.
        #expect(set.weight?.expressed(in: .kilograms).value == 102.1)
    }

    @Test("A set's own unit overrides the lift's, which overrides the app's")
    func setUnitRoundTripsAndIsMostSpecific() throws {
        let database = try AppDatabase.inMemory()
        try ExerciseStore(database).save(ExerciseCatalog.seed)
        let users = UserStore(database, calendar: calendar)
        let user = try users.localUser()
        let workouts = WorkoutStore(database, calendar: calendar)
        let exercise = ExerciseCatalog.seed[0]

        try users.setUnit(.kilograms, forExerciseID: exercise.id, for: user.id)
        try workouts.save(
            Workout(
                exercises: [[WorkoutExercise(
                    exercise: exercise,
                    sets: [
                        WorkoutSet(reps: 5, complete: false, type: .working),
                        WorkoutSet(reps: 5, complete: false, type: .working, unit: .pounds),
                    ]
                )]],
                startTime: Date()
            )
        )

        let reloadedUser = try #require(try users.fetch(id: user.id))
        let sets = try #require(try workouts.fetchInProgress()?.allSets)

        // Set 1 defers, so it reads in the lift's pinned unit.
        #expect(sets[0].unit == nil)
        #expect((sets[0].unit ?? reloadedUser.unit(forExerciseID: exercise.id)) == .kilograms)
        // Set 2 was done on the pound rack and says so.
        #expect(sets[1].unit == .pounds)
        #expect((sets[1].unit ?? reloadedUser.unit(forExerciseID: exercise.id)) == .pounds)
    }
}

import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

/// Pinned to UTC so day-boundary behavior is identical wherever these run —
/// `Calendar.current` would make "same calendar day" depend on the machine's
/// timezone, which is exactly what these tests are asserting about.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let noon = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
private func later(_ seconds: TimeInterval) -> Date { noon.addingTimeInterval(seconds) }

private let squat = ExerciseCatalog.seed[0]
private let bench = ExerciseCatalog.seed[1]
private let row = ExerciseCatalog.seed[4]

private func makeStore() throws -> (WorkoutStore, AppDatabase) {
    let database = try AppDatabase.inMemory()
    try ExerciseStore(database).save(ExerciseCatalog.seed)
    return (WorkoutStore(database, calendar: calendar), database)
}

@Suite("Workout persistence")
struct WorkoutStoreTests {

    @Test("A logged workout round-trips with its sets intact")
    func roundTripsWorkout() throws {
        let (store, _) = try makeStore()

        var session = WorkoutSession.start(
            from: PlannedWorkout(exercises: [[
                PlannedExercise(exercise: squat, sets: [
                    PlannedSet(reps: 5, type: .working, load: .absolute(Measurement(value: 225, unit: .pounds))),
                    PlannedSet(reps: 5, type: .working, load: .absolute(Measurement(value: 225, unit: .pounds))),
                ])
            ]]),
            at: noon
        )
        for set in session.workout.allSets {
            session.completeSet(id: set.id, rpe: 8, at: later(120))
        }
        session.finish(at: later(3600))

        try store.save(session.workout)
        let loaded = try store.fetch(id: session.workout.id)

        #expect(loaded?.id == session.workout.id)
        #expect(loaded?.startTime == noon)
        #expect(loaded?.endTime == later(3600))
        #expect(loaded?.allSets.count == 2)
        #expect(loaded?.allSets.first?.reps == 5)
        #expect(loaded?.allSets.first?.rpe == 8)
        #expect(loaded?.allSets.first?.type == .working)
    }

    @Test("Weights read back in the unit they were logged in")
    func preservesWeightUnits() throws {
        let (store, _) = try makeStore()

        var session = WorkoutSession.adHoc(at: noon)
        let exerciseID = session.addExercise(bench, sets: 1)
        let setID = session.workout.allSets[0].id
        session.completeSet(id: setID, weight: Measurement(value: 185, unit: .pounds), at: later(60))
        _ = exerciseID

        try store.save(session.workout)
        let loaded = try store.fetch(id: session.workout.id)

        // Normalizing to kilograms on the way in would turn 185 lb into an
        // 83.9-ish decimal that never reads back as the number that was lifted.
        #expect(loaded?.allSets.first?.weight?.value == 185)
        #expect(loaded?.allSets.first?.weight?.unit == UnitMass.pounds)
    }

    @Test("Superset grouping survives a round trip")
    func preservesSupersetGrouping() throws {
        let (store, _) = try makeStore()

        let workout = Workout(
            exercises: [
                [WorkoutExercise(exercise: squat, sets: [WorkoutSet(reps: 5, complete: true)])],
                [
                    WorkoutExercise(exercise: bench, sets: [WorkoutSet(reps: 8, complete: true)]),
                    WorkoutExercise(exercise: row, sets: [WorkoutSet(reps: 8, complete: true)]),
                ],
            ],
            startTime: noon
        )

        try store.save(workout)
        let loaded = try store.fetch(id: workout.id)

        #expect(loaded?.exercises?.count == 2)
        #expect(loaded?.exercises?[0].count == 1)
        #expect(loaded?.exercises?[1].count == 2)
        #expect(loaded?.exercises?[1][0].exercise.id == bench.id)
        #expect(loaded?.exercises?[1][1].exercise.id == row.id)
    }

    @Test("The prescription is preserved alongside what was lifted")
    func preservesPrescriptionSnapshot() throws {
        let (store, _) = try makeStore()

        let prescribed = PlannedSet(reps: 5, type: .working, load: .percentOf(0.85, of: .goal))
        var session = WorkoutSession.start(
            from: PlannedWorkout(exercises: [[PlannedExercise(exercise: squat, sets: [prescribed])]]),
            at: noon
        )
        // Lifted three instead of the prescribed five.
        session.completeSet(id: session.workout.allSets[0].id, reps: 3, at: later(60))

        try store.save(session.workout)
        let loaded = try store.fetch(id: session.workout.id)

        let set = loaded?.allSets.first
        #expect(set?.reps == 3)
        #expect(set?.plannedFrom?.reps == 5)
        #expect(set?.plannedFrom?.load == .percentOf(0.85, of: .goal))
    }

    @Test("Tuned rest survives a round trip, without disturbing the prescription")
    func preservesRestOverride() throws {
        let (store, _) = try makeStore()

        let prescribed = PlannedSet(reps: 5, type: .working, restTime: 180)
        var session = WorkoutSession.start(
            from: PlannedWorkout(exercises: [[PlannedExercise(exercise: squat, sets: [prescribed])]]),
            at: noon
        )
        session.setRest(210, forSetWith: session.workout.allSets[0].id)

        try store.save(session.workout)
        let set = try store.fetch(id: session.workout.id)?.allSets.first

        #expect(set?.restOverride == 210)
        // Two columns, two meanings: what the lifter chose, and what the
        // program asked for. Neither overwrites the other.
        #expect(set?.plannedFrom?.restTime == 180)
        // And the legacy measured column stays empty — nothing writes it.
        #expect(set?.restTime == nil)
    }

    @Test("Saving the same workout twice replaces rather than duplicates")
    func saveIsIdempotent() throws {
        let (store, database) = try makeStore()

        var session = WorkoutSession.adHoc(at: noon)
        session.addExercise(squat, sets: 3)
        try store.save(session.workout)

        session.deleteSet(id: session.workout.allSets[0].id)
        try store.save(session.workout)

        let loaded = try store.fetch(id: session.workout.id)
        #expect(loaded?.allSets.count == 2)

        // The replaced rows are gone, not orphaned.
        let totalSets = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workoutSet")
        }
        #expect(totalSets == 2)
    }

    @Test("An exercise added mid-workout is saved even if it wasn't in the catalog")
    func savesUncatalogedExercise() throws {
        let (store, _) = try makeStore()

        var session = WorkoutSession.adHoc(at: noon)
        // Nothing seeded this id — mirrors adding a lift on the fly, which
        // Workout Tracker.md requires. The foreign key would reject it if the
        // store didn't upsert the catalog row first.
        let improvised = Exercise(id: 9_001, name: "Landmine Press", muscleGroup: "Shoulders")
        session.addExercise(improvised, sets: 1)

        try store.save(session.workout)
        let loaded = try store.fetch(id: session.workout.id)

        #expect(loaded?.exercises?.first?.first?.exercise.name == "Landmine Press")
    }

    @Test("Workouts are found by the calendar day they started")
    func fetchesByDay() throws {
        let (store, _) = try makeStore()

        let morning = Workout(
            exercises: [[WorkoutExercise(exercise: squat, sets: [WorkoutSet(reps: 5)])]],
            startTime: noon
        )
        let evening = Workout(
            exercises: [[WorkoutExercise(exercise: bench, sets: [WorkoutSet(reps: 8)])]],
            startTime: later(8 * 3600)
        )
        let anotherDay = Workout(startTime: later(72 * 3600))

        try store.save(morning)
        try store.save(evening)
        try store.save(anotherDay)

        // Two-a-day sessions must both come back for the same date.
        #expect(try store.fetch(on: noon).count == 2)
        #expect(try store.fetch(on: later(72 * 3600)).count == 1)
        #expect(try store.fetch(on: later(300 * 3600)).isEmpty)
    }

    @Test("A range query returns workouts oldest first")
    func fetchesRange() throws {
        let (store, _) = try makeStore()

        try store.save(Workout(startTime: later(48 * 3600)))
        try store.save(Workout(startTime: noon))

        let range = try store.fetch(from: noon, to: later(72 * 3600))
        #expect(range.count == 2)
        #expect(range.first?.startTime == noon)
    }

    @Test("An interrupted workout can be recovered")
    func findsInProgressWorkout() throws {
        let (store, _) = try makeStore()

        // The app being killed mid-session is the normal case, not the edge one —
        // the phone goes in a bag between sets.
        let finished = Workout(startTime: noon, endTime: later(3600))
        let interrupted = Workout(
            exercises: [[WorkoutExercise(exercise: squat, sets: [WorkoutSet(reps: 5, complete: true)])]],
            startTime: later(7200)
        )
        try store.save(finished)
        try store.save(interrupted)

        let recovered = try store.fetchInProgress()
        #expect(recovered?.id == interrupted.id)
        #expect(recovered?.allSets.count == 1)
    }

    @Test("No in-progress workout once everything is finished")
    func noInProgressWhenAllFinished() throws {
        let (store, _) = try makeStore()
        try store.save(Workout(startTime: noon, endTime: later(3600)))

        #expect(try store.fetchInProgress() == nil)
    }

    @Test("Deleting a workout removes its sets too")
    func deleteCascades() throws {
        let (store, database) = try makeStore()

        var session = WorkoutSession.adHoc(at: noon)
        session.addExercise(squat, sets: 3)
        try store.save(session.workout)

        try store.delete(id: session.workout.id)

        #expect(try store.fetch(id: session.workout.id) == nil)
        let orphans = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workoutSet")
        }
        #expect(orphans == 0)
    }
}

@Suite("Superset round trip")
struct SupersetPersistenceTests {

    /// The nesting is flattened to `groupIndex`/`position` on write and rebuilt
    /// by watching `groupIndex` advance on read. A group formed mid-workout has
    /// to survive that round trip — this is the assertion that catches a
    /// `superset`/`ungroup` implementation leaving a hole in the indices, which
    /// re-nests the whole workout wrongly on the next launch rather than
    /// failing outright.
    @Test("A superset formed mid-workout reloads with its grouping intact")
    func groupingSurvivesReload() throws {
        let database = try AppDatabase.inMemory()
        try ExerciseStore(database).save(ExerciseCatalog.seed)
        let store = WorkoutStore(database)

        var session = WorkoutSession.adHoc(at: Date())
        session.addExercise(ExerciseCatalog.seed[0], sets: 1)
        session.addExercise(ExerciseCatalog.seed[1], sets: 1)
        session.addExercise(ExerciseCatalog.seed[4], sets: 1)

        // Pair the first into the last — the case that empties a group and
        // shifts every index after it.
        let firstID = session.exerciseGroups[0][0].id
        let lastID = session.exerciseGroups[2][0].id
        let paired = session.superset(id: firstID, with: lastID)
        #expect(paired)

        let expected = session.exerciseGroups.map { $0.map(\.exercise.id) }
        try store.save(session.workout)

        let reloaded = try #require(try store.fetchInProgress())
        #expect((reloaded.exercises ?? []).map { $0.map(\.exercise.id) } == expected)
        #expect((reloaded.exercises ?? []).allSatisfy { !$0.isEmpty })
    }

    @Test("Ungrouping reloads as separate exercises")
    func ungroupingSurvivesReload() throws {
        let database = try AppDatabase.inMemory()
        try ExerciseStore(database).save(ExerciseCatalog.seed)
        let store = WorkoutStore(database)

        var session = WorkoutSession.adHoc(at: Date())
        session.addExercise(ExerciseCatalog.seed[0], sets: 1)
        session.addExercise(ExerciseCatalog.seed[1], sets: 1)
        let secondID = session.exerciseGroups[1][0].id
        let firstID = session.exerciseGroups[0][0].id
        _ = session.superset(id: secondID, with: firstID)
        let split = session.ungroup(id: secondID)
        #expect(split)

        try store.save(session.workout)

        let reloaded = try #require(try store.fetchInProgress())
        #expect((reloaded.exercises ?? []).count == 2)
        #expect((reloaded.exercises ?? []).allSatisfy { $0.count == 1 })
    }

    // MARK: Duration, distance, provenance

    /// Time-and-distance work has no reps and no weight, which is a complete
    /// record rather than an empty one. If either field silently dropped on the
    /// way to SQLite, a logged bike ride would read back as a set of nothing.
    @Test("A time-and-distance set round-trips")
    func roundTripsDurationAndDistance() throws {
        let (store, _) = try makeStore()

        var workout = Workout(startTime: noon, endTime: later(1800), source: "strong-csv")
        workout.exercises = [[
            WorkoutExercise(exercise: squat, sets: [
                WorkoutSet(
                    complete: true,
                    type: .working,
                    duration: Measurement(value: 720, unit: .seconds),
                    distance: Measurement(value: 2.4, unit: .miles)
                )
            ])
        ]]
        try store.save(workout)

        let set = try #require(try store.fetch(id: workout.id)?.allSets.first)
        #expect(set.reps == nil)
        #expect(set.weight == nil)
        #expect(set.duration?.converted(to: .seconds).value == 720)
        #expect(set.distance?.value == 2.4)
        // Stored with its own unit rather than normalized: 2.4 miles reads back
        // as 2.4 miles, not as an approximate number of kilometers.
        #expect(set.distance?.unit.symbol == UnitLength.miles.symbol)
    }

    @Test("Provenance round-trips, and a workout logged here has none")
    func roundTripsSource() throws {
        let (store, _) = try makeStore()

        let imported = Workout(startTime: noon, endTime: later(60), source: "strong-csv")
        let logged = Workout(startTime: later(7200), endTime: later(7260))
        try store.save(imported)
        try store.save(logged)

        #expect(try store.fetch(id: imported.id)?.source == "strong-csv")
        #expect(try store.fetch(id: logged.id)?.source == nil)
    }

    // MARK: Summaries

    /// The load-bearing invariant: the cheap query and the expensive one must
    /// describe the same workouts. `fetchSummaries` exists purely so History
    /// stops hydrating thousands of sets to draw a list, and the moment it
    /// disagrees with `fetch` it is showing something that isn't there.
    @Test("Summaries agree with the fully hydrated fetch")
    func summariesAgreeWithHydratedFetch() throws {
        let (store, _) = try makeStore()

        for (index, exercise) in [squat, bench, row].enumerated() {
            let start = later(Double(index) * 86_400)
            var workout = Workout(
                startTime: start,
                endTime: start.addingTimeInterval(3600),
                notes: "Day \(index)"
            )
            workout.exercises = [[
                WorkoutExercise(exercise: exercise, sets: [
                    WorkoutSet(reps: 5, complete: true, type: .working),
                    WorkoutSet(reps: 5, complete: true, type: .working),
                    // Not completed, so it must not be counted.
                    WorkoutSet(reps: 5, type: .working),
                ])
            ]]
            try store.save(workout)
        }

        let summaries = try store.fetchSummaries(limit: 10)
        #expect(summaries.count == 3)

        for summary in summaries {
            let hydrated = try #require(try store.fetch(id: summary.id))
            #expect(summary.startTime == hydrated.startTime)
            #expect(summary.endTime == hydrated.endTime)
            #expect(summary.notes == hydrated.notes)
            #expect(summary.source == hydrated.source)
            #expect(summary.completedSetCount
                == hydrated.allSets.filter { $0.complete == true }.count)
            #expect(summary.exerciseNames
                == (hydrated.exercises ?? []).flatMap { $0 }.map(\.displayName))
        }
    }

    /// The plan's own wording is what the lifter sees everywhere else, so a
    /// summary showing the catalog name instead would make one workout read as
    /// two different sessions depending on which screen you were on.
    @Test("Summaries show the variant where there is one")
    func summariesUseDisplayName() throws {
        let (store, _) = try makeStore()

        var workout = Workout(startTime: noon, endTime: later(60))
        workout.exercises = [[
            WorkoutExercise(exercise: bench, variant: "Bench — paused"),
            WorkoutExercise(exercise: squat),
        ]]
        try store.save(workout)

        let summary = try #require(try store.fetchSummaries(limit: 1).first)
        #expect(summary.exerciseNames == ["Bench — paused", squat.name])
    }

    @Test("Summaries are newest first and page backwards")
    func summariesPage() throws {
        let (store, _) = try makeStore()

        for index in 0..<5 {
            let start = later(Double(index) * 86_400)
            try store.save(
                Workout(startTime: start, endTime: start.addingTimeInterval(60))
            )
        }

        let first = try store.fetchSummaries(limit: 2)
        #expect(first.count == 2)
        #expect(first[0].startTime == later(4 * 86_400))
        #expect(first[1].startTime == later(3 * 86_400))

        let next = try store.fetchSummaries(limit: 2, before: first[1].startTime)
        #expect(next.map(\.startTime) == [later(2 * 86_400), later(86_400)])
    }

    /// History is finished workouts. The in-progress one belongs to the
    /// tracker, and listing it would offer a way to open a session that is
    /// still being written.
    @Test("Summaries exclude the in-progress workout")
    func summariesExcludeInProgress() throws {
        let (store, _) = try makeStore()

        try store.save(Workout(startTime: noon, endTime: later(3600)))
        try store.save(Workout(startTime: later(7200)))

        let summaries = try store.fetchSummaries(limit: 10)
        #expect(summaries.count == 1)
        #expect(summaries[0].startTime == noon)
    }
}

import Foundation
import Testing
import GRDB
import LiftingCoachModel
@testable import LiftingCoachPersistence

private let squat = ExerciseCatalog.seed[0]
private let bench = ExerciseCatalog.seed[1]

private let day0 = Date(timeIntervalSince1970: 1_700_000_000)
private func day(_ n: Int) -> Date { day0.addingTimeInterval(Double(n) * 86_400) }

private func makeStores() throws -> (WorkoutStore, ExerciseStatsStore, UserStore, User) {
    let database = try AppDatabase.inMemory()
    try ExerciseStore(database).save(ExerciseCatalog.seed)
    let users = UserStore(database)
    return (WorkoutStore(database), ExerciseStatsStore(database), users, try users.localUser())
}

/// A finished workout of one exercise.
private func finished(
    _ exercise: Exercise,
    on date: Date,
    sets: [WorkoutSet]
) -> Workout {
    Workout(
        exercises: [[WorkoutExercise(exercise: exercise, sets: sets)]],
        startTime: date,
        endTime: date.addingTimeInterval(3600)
    )
}

private func working(_ reps: Int, _ pounds: Double) -> WorkoutSet {
    WorkoutSet(
        reps: reps,
        weight: Measurement(value: pounds, unit: .pounds),
        complete: true,
        type: .working
    )
}

@Suite("Exercise stats")
struct ExerciseStatsStoreTests {

    @Test("Counts sessions and sets across completed workouts")
    func countsAcrossWorkouts() throws {
        let (workouts, stats, _, user) = try makeStores()
        try workouts.save(finished(squat, on: day(0), sets: [working(5, 225), working(5, 225)]))
        try workouts.save(finished(squat, on: day(2), sets: [working(3, 245)]))
        try workouts.save(finished(bench, on: day(2), sets: [working(8, 135)]))

        try stats.rebuild(for: user.id)
        let all = try stats.stats(for: user.id)

        #expect(all[squat.id]?.sessionCount == 2)
        #expect(all[squat.id]?.setCount == 3)
        #expect(all[bench.id]?.sessionCount == 1)
    }

    @Test("An in-progress workout is not history yet")
    func excludesInProgress() throws {
        let (workouts, stats, _, user) = try makeStores()
        try workouts.save(finished(squat, on: day(0), sets: [working(5, 225)]))
        // Started, never ended — the session the lifter is in right now.
        try workouts.save(
            Workout(
                exercises: [[WorkoutExercise(exercise: squat, sets: [working(5, 315)])]],
                startTime: day(1)
            )
        )

        try stats.rebuild(for: user.id)
        let all = try stats.stats(for: user.id)

        #expect(all[squat.id]?.sessionCount == 1)
        // And critically, the heaviest doesn't pick up the live session — which
        // is what would make the tracker suggest the set you're looking at.
        #expect(all[squat.id]?.heaviestWorkingSet?.value == 225)
    }

    @Test("lastPerformed is the most recent completed session")
    func tracksLastPerformed() throws {
        let (workouts, stats, _, user) = try makeStores()
        try workouts.save(finished(squat, on: day(5), sets: [working(5, 225)]))
        try workouts.save(finished(squat, on: day(1), sets: [working(5, 205)]))

        try stats.rebuild(for: user.id)

        let last = try #require(try stats.stats(for: user.id)[squat.id]?.lastPerformed)
        #expect(abs(last.timeIntervalSince(day(5))) < 1)
    }

    @Test("Heaviest ignores warmups and drop sets")
    func heaviestIsWorkingOnly() throws {
        let (workouts, stats, _, user) = try makeStores()
        try workouts.save(finished(squat, on: day(0), sets: [
            WorkoutSet(reps: 1, weight: Measurement(value: 500, unit: .pounds),
                       complete: true, type: .warmup),
            working(3, 315),
            WorkoutSet(reps: 8, weight: Measurement(value: 495, unit: .pounds),
                       complete: true, type: .drop),
        ]))

        try stats.rebuild(for: user.id)

        // 500 and 495 are both heavier, and neither is an attempt at a limit.
        #expect(try stats.stats(for: user.id)[squat.id]?.heaviestWorkingSet?.value == 315)
    }

    @Test("Heaviest compares across units but reports the unit it was logged in")
    func heaviestComparesInKilograms() throws {
        let (workouts, stats, _, user) = try makeStores()
        try workouts.save(finished(squat, on: day(0), sets: [
            working(3, 300),  // 300 lb ≈ 136 kg
            WorkoutSet(reps: 3, weight: Measurement(value: 150, unit: .kilograms),
                       complete: true, type: .working),  // heavier
        ]))

        try stats.rebuild(for: user.id)

        let heaviest = try #require(try stats.stats(for: user.id)[squat.id]?.heaviestWorkingSet)
        #expect(heaviest.value == 150)
        // Reported as logged — normalizing storage would round what was typed.
        #expect(heaviest.unit == .kilograms)
    }

    @Test("Sessions come back newest first, with their sets")
    func sessionsAreNewestFirst() throws {
        let (workouts, stats, _, _) = try makeStores()
        try workouts.save(finished(squat, on: day(1), sets: [working(5, 205)]))
        try workouts.save(finished(squat, on: day(9), sets: [working(3, 275), working(3, 275)]))

        let sessions = try stats.sessions(forExerciseID: squat.id)

        #expect(sessions.count == 2)
        #expect(abs(sessions[0].date.timeIntervalSince(day(9))) < 1)
        #expect(sessions[0].sets.count == 2)
        #expect(sessions[0].sets.first?.weight?.value == 275)
        #expect(sessions[1].sets.first?.weight?.value == 205)
    }

    @Test("lastSession is the most recent one")
    func lastSessionIsMostRecent() throws {
        let (workouts, stats, _, _) = try makeStores()
        try workouts.save(finished(bench, on: day(1), sets: [working(8, 135)]))
        try workouts.save(finished(bench, on: day(4), sets: [working(6, 155)]))

        let last = try #require(try stats.lastSession(forExerciseID: bench.id))
        #expect(last.sets.first?.weight?.value == 155)
    }

    // MARK: The invariant that makes a derived table safe

    @Test("Rebuild is idempotent")
    func rebuildIsIdempotent() throws {
        let (workouts, stats, _, user) = try makeStores()
        try workouts.save(finished(squat, on: day(0), sets: [working(5, 225), working(5, 225)]))
        try workouts.save(finished(bench, on: day(1), sets: [working(8, 135)]))

        try stats.rebuild(for: user.id)
        let once = try stats.stats(for: user.id)
        try stats.rebuild(for: user.id)
        try stats.rebuild(for: user.id)
        let thrice = try stats.stats(for: user.id)

        // Running it again must never double a count or accumulate rows. This
        // is the property a hand-maintained counter cannot offer.
        #expect(once == thrice)
        #expect(thrice.count == 2)
    }

    @Test("Rebuild agrees with the equivalent live query")
    func rebuildAgreesWithTheLog() throws {
        let database = try AppDatabase.inMemory()
        try ExerciseStore(database).save(ExerciseCatalog.seed)
        let users = UserStore(database)
        let user = try users.localUser()
        let workouts = WorkoutStore(database)
        let stats = ExerciseStatsStore(database)

        for n in 0..<6 {
            try workouts.save(finished(
                n.isMultiple(of: 2) ? squat : bench,
                on: day(n),
                sets: [working(5, 200 + Double(n) * 10), working(5, 200)]
            ))
        }
        // An abandoned session, which must not count.
        try workouts.save(
            Workout(exercises: [[WorkoutExercise(exercise: squat, sets: [working(1, 999)])]],
                    startTime: day(20))
        )

        try stats.rebuild(for: user.id)
        let stored = try stats.stats(for: user.id)

        // The same question asked directly of the log. If the table can drift
        // from this, the table is a liability rather than a cache — so this is
        // the assertion to keep as write paths get added.
        let live = try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT we.exerciseId AS eid,
                       COUNT(DISTINCT we.workoutId) AS sessions,
                       COUNT(ws.id) AS sets
                  FROM workoutExercise we
                  JOIN workout w ON w.id = we.workoutId
                  LEFT JOIN workoutSet ws
                         ON ws.workoutExerciseId = we.id AND ws.complete = 1
                 WHERE w.endTime IS NOT NULL
                 GROUP BY we.exerciseId
                """)
            .reduce(into: [Int: (Int, Int)]()) { $0[$1["eid"]] = ($1["sessions"], $1["sets"]) }
        }

        #expect(stored.count == live.count)
        for (exerciseID, expected) in live {
            #expect(stored[exerciseID]?.sessionCount == expected.0)
            #expect(stored[exerciseID]?.setCount == expected.1)
        }
    }

    @Test("Rebuilding after a workout is deleted drops it from the counts")
    func rebuildReflectsDeletion() throws {
        let (workouts, stats, _, user) = try makeStores()
        let doomed = finished(squat, on: day(0), sets: [working(5, 225)])
        try workouts.save(doomed)
        try workouts.save(finished(squat, on: day(1), sets: [working(5, 235)]))
        try stats.rebuild(for: user.id)
        #expect(try stats.stats(for: user.id)[squat.id]?.sessionCount == 2)

        try workouts.delete(id: doomed.id)
        try stats.rebuild(for: user.id)

        // A counter would have needed a correct decrement here. Recomputation
        // just gets it right.
        #expect(try stats.stats(for: user.id)[squat.id]?.sessionCount == 1)
        #expect(try stats.stats(for: user.id)[squat.id]?.heaviestWorkingSet?.value == 235)
    }

    @Test("A lifter with no history has no rows rather than zeroed ones")
    func emptyHistoryIsEmpty() throws {
        let (_, stats, _, user) = try makeStores()
        try stats.rebuild(for: user.id)
        #expect(try stats.stats(for: user.id).isEmpty)
    }
}

import Foundation
import GRDB
import LiftingCoachModel
import Testing
@testable import LiftingCoachPersistence

/// Migrations against a database that already holds someone's training.
///
/// The app is local-first: a tester's whole log lives in one SQLite file on
/// their phone and there is no server copy to rebuild from. So "the new build
/// opens the old database and nothing is lost" is not a thing to assume from
/// the shape of an `ALTER TABLE` — it's the thing to assert.
///
/// `eraseDatabaseOnSchemaChange` is DEBUG-only, and these tests run in DEBUG,
/// which means they run *with* the safety net that a TestFlight build does not
/// have. That cuts the right way: if a migration were destructive enough to
/// trip the schema check, the erase would hide it here and not there. What
/// these assert is the outcome a Release build produces — rows still present,
/// values intact, new column defaulted.
@Suite("Migrating an existing database")
struct MigrationTests {

    /// Stops at a named migration, the way a phone running an older build has.
    private func database(upTo migration: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue, upTo: migration)
        return queue
    }

    @Test("A v13 database carrying a program migrates forward with every row intact")
    func v13ProgramSurvivesV14() throws {
        let queue = try database(upTo: "v13_setDurationDistance")

        // A program written the only way build 68 could write one: one row per
        // set. Three sets of five at 72.5% of goal.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO user (id, name, email) VALUES ('U', 'Rob', 'r@example.com');
                INSERT INTO exercise (id, name, muscleGroup) VALUES (1, 'Barbell Squat', 'Quadriceps');
                INSERT INTO block (id, userId, startDate) VALUES ('B', 'U', '2026-03-01 08:00:00.000');
                INSERT INTO plannedWorkout (id, blockId, date) VALUES ('W', 'B', '2026-03-02 08:00:00.000');
                INSERT INTO plannedExercise (id, plannedWorkoutId, exerciseId, groupIndex, position, effortRPE)
                    VALUES ('E', 'W', 1, 0, 0, 7.0);
                """)
            for (index, id) in ["S1", "S2", "S3"].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO plannedSet
                            (id, plannedExerciseId, position, reps, setType, loadKind, loadValue, loadMaxRef, restTime)
                        VALUES (?, 'E', ?, 5, 'working', 'percentOf', 0.725, 'goal', 180)
                        """,
                    arguments: [id, index]
                )
            }
        }

        // The new build opens it.
        try AppDatabase.migrator.migrate(queue)

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM plannedSet ORDER BY position")
        }
        // Three rows, still three rows. **Nothing collapses them**, deliberately
        // — four identical rows look like a 4x5 but merging them is the app
        // deciding what an author meant, and it would take three set ids down
        // to one (Core Tenets §1).
        #expect(rows.count == 3)
        #expect(rows.map { $0["id"] as String } == ["S1", "S2", "S3"])
        // Absent means one, which is what these rows have always meant.
        #expect(rows.allSatisfy { ($0["setCount"] as Int) == 1 })
        // And the prescription itself is untouched.
        #expect(rows.allSatisfy { ($0["reps"] as Int?) == 5 })
        #expect(rows.allSatisfy { ($0["loadValue"] as Double?) == 0.725 })
        #expect(rows.allSatisfy { ($0["restTime"] as Int?) == 180 })
    }

    @Test("A logged set's plannedFrom snapshot still decodes after the count field lands")
    func v13SnapshotStillLoads() throws {
        let queue = try database(upTo: "v13_setDurationDistance")
        let workoutID = UUID()

        // The exact JSON build 68 wrote: a `PlannedSet` with no `count` key.
        // Synthesized decoding of a non-optional Int would refuse this, and for
        // `plannedFrom` that means a workout that no longer loads at all — the
        // one way this change could have destroyed a tester's history.
        let snapshot = #"{"id":"F1B0B1E2-0000-0000-0000-000000000001","reps":5,"type":"working","restTime":180}"#
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO user (id, name, email) VALUES ('U', 'Rob', 'r@example.com');
                INSERT INTO exercise (id, name, muscleGroup) VALUES (1, 'Barbell Squat', 'Quadriceps');
                """)
            try db.execute(
                sql: """
                    INSERT INTO workout (id, day, startTime, endTime)
                    VALUES (?, '2026-03-02 08:00:00.000', '2026-03-02 17:00:00.000', '2026-03-02 18:00:00.000')
                    """,
                arguments: [workoutID.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO workoutExercise (id, workoutId, exerciseId, groupIndex, position)
                    VALUES ('E', ?, 1, 0, 0)
                    """,
                arguments: [workoutID.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO workoutSet
                        (id, workoutExerciseId, position, reps, weightValue, weightUnit, complete, setType, plannedFrom)
                    VALUES ('S', 'E', 0, 5, 225, 'lb', 1, 'working', ?)
                    """,
                arguments: [snapshot]
            )
        }

        let database = try AppDatabase(queue)
        let loaded = try #require(try WorkoutStore(database).fetch(id: workoutID))
        let set = try #require(loaded.allSets.first)

        #expect(set.reps == 5)
        #expect(set.weight?.value == 225)
        let prescription = try #require(set.plannedFrom)
        #expect(prescription.reps == 5)
        #expect(prescription.restTime == 180)
        // Absent means one.
        #expect(prescription.count == 1)
    }
}

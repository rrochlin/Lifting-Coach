import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

@Suite("SQLite store")
struct ExerciseStoreTests {

    @Test("Migrations apply to a fresh database")
    func migratesCleanly() throws {
        let database = try AppDatabase.inMemory()

        let tables = try database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }

        for expected in ["block", "exercise", "plannedSet", "user", "workout", "workoutSet"] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
    }

    @Test("Round-trips the seed catalog through SQLite")
    func roundTripsCatalog() throws {
        let store = ExerciseStore(try AppDatabase.inMemory())
        try store.save(ExerciseCatalog.seed)

        let all = try store.fetchAll()
        #expect(all.count == ExerciseCatalog.seed.count)

        let bench = try store.fetch(id: 2)
        #expect(bench?.name == "Bench Press")
        #expect(bench?.muscleGroup == "Chest")
    }

    @Test("Saving an existing id updates rather than duplicating")
    func saveIsUpsert() throws {
        let store = ExerciseStore(try AppDatabase.inMemory())
        try store.save(Exercise(id: 1, name: "Back Squat", muscleGroup: "Quads"))
        try store.save(Exercise(id: 1, name: "High Bar Squat", muscleGroup: "Quads"))

        let all = try store.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "High Bar Squat")
    }

    @Test("Search matches on partial name")
    func searchesByName() throws {
        let store = ExerciseStore(try AppDatabase.inMemory())
        try store.save(ExerciseCatalog.seed)

        let results = try store.search("Squat")
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.name.contains("Squat") })
    }

    @Test("Deleting a logged set's prescription preserves the logged set")
    func editingPlanNeverDeletesHistory() throws {
        // The safety property from Design.md: the coach editing a plan must not
        // destroy what was actually lifted. Enforced here as ON DELETE SET NULL.
        let database = try AppDatabase.inMemory()

        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO user (id, name, email) VALUES ('u1', 'Rob', 'r@example.com');
                INSERT INTO exercise (id, name, muscleGroup) VALUES (1, 'Bench Press', 'Chest');
                INSERT INTO block (id, userId) VALUES ('b1', 'u1');
                INSERT INTO plannedWorkout (id, blockId) VALUES ('pw1', 'b1');
                INSERT INTO plannedExercise (id, plannedWorkoutId, exerciseId, groupIndex, position)
                    VALUES ('pe1', 'pw1', 1, 0, 0);
                INSERT INTO plannedSet (id, plannedExerciseId, position, reps)
                    VALUES ('ps1', 'pe1', 0, 5);
                INSERT INTO workout (id, blockId) VALUES ('w1', 'b1');
                INSERT INTO workoutExercise (id, workoutId, exerciseId, groupIndex, position)
                    VALUES ('we1', 'w1', 1, 0, 0);
                INSERT INTO workoutSet (id, workoutExerciseId, position, reps, plannedFromId)
                    VALUES ('ws1', 'we1', 0, 5, 'ps1');
                """)
        }

        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM plannedSet WHERE id = 'ps1'")
        }

        let survived = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workoutSet WHERE id = 'ws1'")
        }
        #expect(survived == 1)
    }
}

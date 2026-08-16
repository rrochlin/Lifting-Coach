import Foundation
import GRDB

extension AppDatabase {
    /// Schema history. Migrations are append-only and never edited once they
    /// have shipped to a device — add a new one instead.
    ///
    /// The schema mirrors the types in `LiftingCoachModel` (and therefore
    /// `notes/Workout App/Concepts.md`). Two shape notes:
    ///
    /// - The `[[Exercise]]` superset nesting in `Workout`/`PlannedWorkout` is
    ///   flattened here into `group_index` (which superset group) plus
    ///   `position` (order within the group). Rebuilding the nested arrays is
    ///   the store's job, not the schema's.
    /// - Weights are stored as a value plus a unit symbol rather than
    ///   normalizing to kilograms, so a set logged in pounds reads back in
    ///   pounds without a lossy round trip.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Recreate the database from scratch when a shipped migration changes.
        // Safe only while phase 1 has no real user data to lose.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_core") { db in
            try db.create(table: "exercise") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
                t.column("muscleGroup", .text).notNull()
            }

            try db.create(table: "user") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("email", .text).notNull()
            }

            try db.create(table: "bodyWeight") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("userId", .text).notNull()
                    .references("user", onDelete: .cascade)
                // Start of day.
                t.column("day", .datetime).notNull()
                t.column("value", .double).notNull()
                t.column("unit", .text).notNull()
                t.uniqueKey(["userId", "day"])
            }

            // Achieved maxes are events — append-only history, never upserted;
            // the newest by date is what an `.achieved` reference resolves to.
            try db.create(table: "achievedMax") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("userId", .text).notNull()
                    .references("user", onDelete: .cascade)
                t.column("exerciseId", .integer).notNull()
                    .references("exercise", onDelete: .cascade)
                t.column("value", .double).notNull()
                t.column("unit", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("notes", .text)
            }
            try db.create(index: "achievedMax_on_user_exercise", on: "achievedMax", columns: ["userId", "exerciseId"])

            // Goal maxes are settings — one per lift, replaced when a new goal
            // is set deliberately.
            try db.create(table: "goalMax") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("userId", .text).notNull()
                    .references("user", onDelete: .cascade)
                t.column("exerciseId", .integer).notNull()
                    .references("exercise", onDelete: .cascade)
                t.column("value", .double).notNull()
                t.column("unit", .text).notNull()
                t.column("dateSet", .datetime)
                t.uniqueKey(["userId", "exerciseId"])
            }

            try db.create(table: "block") { t in
                t.primaryKey("id", .text)
                t.column("userId", .text).notNull()
                    .references("user", onDelete: .cascade)
                t.column("startDate", .datetime)
                // Planned end only — never treat this as "the block is over".
                t.column("endDate", .datetime)
                t.column("notes", .text)
                t.column("journal", .text)
            }
            try db.create(index: "block_on_userId_startDate", on: "block", columns: ["userId", "startDate"])

            try db.create(table: "blockDefaultRest") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("blockId", .text).notNull()
                    .references("block", onDelete: .cascade)
                t.column("setType", .text).notNull()
                t.column("seconds", .integer).notNull()
                t.uniqueKey(["blockId", "setType"])
            }

            try db.create(table: "plannedWorkout") { t in
                t.primaryKey("id", .text)
                t.column("blockId", .text).notNull()
                    .references("block", onDelete: .cascade)
                // Start of day.
                t.column("date", .datetime)
                t.column("notes", .text)
            }
            try db.create(index: "plannedWorkout_on_blockId_date", on: "plannedWorkout", columns: ["blockId", "date"])

            try db.create(table: "plannedExercise") { t in
                t.primaryKey("id", .text)
                t.column("plannedWorkoutId", .text).notNull()
                    .references("plannedWorkout", onDelete: .cascade)
                t.column("exerciseId", .integer).notNull()
                    .references("exercise")
                t.column("groupIndex", .integer).notNull()
                t.column("position", .integer).notNull()
                // the exercise-level effort target ("5x2 @ RPE 7" is one
                // instruction); sets override via their own effortRPE
                t.column("effortRPE", .double)
                t.column("notes", .text)
            }

            try db.create(table: "plannedSet") { t in
                t.primaryKey("id", .text)
                t.column("plannedExerciseId", .text).notNull()
                    .references("plannedExercise", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("reps", .integer)
                t.column("setType", .text)
                // LoadPrescription, flattened: kind is absolute | percentOf.
                // maxRef (achieved | goal | theoretical) applies to percentOf.
                t.column("loadKind", .text)
                t.column("loadValue", .double)
                t.column("loadUnit", .text)
                t.column("loadMaxRef", .text)
                // per-set effort override; nil defers to the exercise's target
                t.column("effortRPE", .double)
                t.column("restTime", .integer)
                t.column("notes", .text)
            }

            try db.create(table: "workout") { t in
                t.primaryKey("id", .text)
                t.column("blockId", .text)
                    .references("block", onDelete: .setNull)
                // Start of day, for calendar lookups.
                t.column("day", .datetime)
                t.column("startTime", .datetime)
                t.column("endTime", .datetime)
                t.column("notes", .text)
                t.column("usernotes", .text)
            }
            try db.create(index: "workout_on_day", on: "workout", columns: ["day"])

            try db.create(table: "workoutExercise") { t in
                t.primaryKey("id", .text)
                t.column("workoutId", .text).notNull()
                    .references("workout", onDelete: .cascade)
                t.column("exerciseId", .integer).notNull()
                    .references("exercise")
                t.column("groupIndex", .integer).notNull()
                t.column("position", .integer).notNull()
                t.column("notes", .text)
                t.column("usernotes", .text)
            }

            try db.create(table: "workoutSet") { t in
                t.primaryKey("id", .text)
                t.column("workoutExerciseId", .text).notNull()
                    .references("workoutExercise", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("reps", .integer)
                t.column("weightValue", .double)
                t.column("weightUnit", .text)
                t.column("complete", .boolean)
                t.column("setType", .text)
                t.column("timeComplete", .datetime)
                t.column("restTime", .integer)
                t.column("rpe", .double)
                t.column("notes", .text)
                t.column("usernotes", .text)
                // The prescription this set was performed against, stored as a
                // JSON snapshot rather than a foreign key into `plannedSet`.
                //
                // `Concepts.md` embeds `plannedFrom` by value, and that turns out
                // to be the right call for storage too: logged history stays
                // self-contained, so editing or deleting a plan cannot reach into
                // what was actually lifted. That's Design.md's safety requirement
                // enforced by shape instead of by a delete rule — and it's also
                // what lets a workout be logged from a plan that was never saved.
                //
                // Tradeoff: prescribed values aren't directly queryable. Fine for
                // phase 1, where adherence is computed per workout in memory;
                // revisit if plan-wide analytics need to filter on them in SQL.
                t.column("plannedFrom", .jsonText)
            }
        }

        return migrator
    }
}

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
        // Recreate the database from scratch if the actual on-disk schema ever
        // stops matching what a fresh run of these migrations would produce.
        //
        // The device this ever runs on is a dev phone whose data is expendable
        // by the owner's own call, so an erase here costs scratch data rather
        // than someone's training history. That's what makes editing a
        // migration in place merely rude instead of destructive.
        //
        // Still prefer appending a migration to editing one: an erase throws
        // away whatever you were mid-way through testing, and this flag stops
        // being a safety net the day phase 2 puts this app on a phone that
        // matters. Treat "additive by default" as the habit, not the rule.
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

        // Additive: the first migration since a real device started carrying
        // real data. Alters existing tables rather than editing v1_core, so a
        // phone that already has rows keeps them — see the note on
        // eraseDatabaseOnSchemaChange above for what editing v1 in place would
        // have done instead.
        //
        // Backs `Exercise`'s new catalog-metadata fields (see Exercise.swift
        // and Concepts.md's #Exercise section). Array-typed fields
        // (primaryMuscles, secondaryMuscles, instructions) are JSON-encoded
        // text, the same pattern `workoutSet.plannedFrom` already established,
        // rather than new child tables — this is read-mostly reference data,
        // not something queried by muscle group from SQL today.
        migrator.registerMigration("v2_exerciseCatalog") { db in
            try db.alter(table: "exercise") { t in
                t.add(column: "equipment", .text)
                t.add(column: "primaryMuscles", .jsonText)
                t.add(column: "secondaryMuscles", .jsonText)
                t.add(column: "instructions", .jsonText)
                t.add(column: "level", .text)
                t.add(column: "category", .text)
                t.add(column: "mechanic", .text)
                t.add(column: "force", .text)
                t.add(column: "sourceSlug", .text)
                // Held what a name matcher guessed an exercise probably was.
                // Dropped again in v8 — programs name their exercises by slug
                // outright, so there is nothing to guess.
                t.add(column: "matchedSlug", .text)
            }
            // Unique only where present — lets a re-import upsert a
            // catalog-sourced row by identity instead of duplicating it, while
            // manually-created exercises (sourceSlug nil) are unconstrained by
            // it. SQLite treats every NULL as distinct for uniqueness, so any
            // number of nil rows coexist fine.
            try db.create(
                index: "exercise_on_sourceSlug",
                on: "exercise",
                columns: ["sourceSlug"],
                unique: true
            )
        }

        // Additive, same reasoning as v2 above.
        //
        // Marks an exercise as naming a goal/muscle group rather than one
        // specific movement ("45 min LSS cardio," "pick a triceps exercise")
        // — see Exercise.isOpenChoice. Exists so AchievedMaxUpdate can refuse
        // to compare weights across what might be entirely different lifts.
        migrator.registerMigration("v3_openChoiceExercises") { db in
            try db.alter(table: "exercise") { t in
                t.add(column: "isOpenChoice", .boolean).notNull().defaults(to: false)
            }
        }

        // Additive, same reasoning as v2/v3 above — a real device now holds
        // real data.
        //
        // Backs PlannedWorkout.skippedAt (Concepts.md): a skip must survive as
        // a persisted, visible status, not a client-side dismiss.
        migrator.registerMigration("v4_skippedWorkouts") { db in
            try db.alter(table: "plannedWorkout") { t in
                t.add(column: "skippedAt", .datetime)
            }
        }

        // Additive, same reasoning as v2-v4 above.
        //
        // Backs PlannedExercise.variant / WorkoutExercise.variant: how a lift
        // is being done today, in the program's own words ("heavy, paused",
        // "Spoto press"). Needed once the program resolves onto canonical
        // catalog entries — Monday's heavy paused bench and its back-off sets
        // are the same catalog lift and correctly share a max, but they're two
        // different instructions, and without this a day prescribing both
        // renders as one exercise listed twice.
        //
        // A plain column on each side rather than on `exercise`: this is
        // prescription, not catalog identity. Two different variants of the
        // same lift must keep resolving to the same exercise row.
        migrator.registerMigration("v5_exerciseVariant") { db in
            try db.alter(table: "plannedExercise") { t in
                t.add(column: "variant", .text)
            }
            try db.alter(table: "workoutExercise") { t in
                t.add(column: "variant", .text)
            }
        }

        // Additive, same reasoning as v2-v5 above.
        //
        // Backs WorkoutSet.restOverride: rest the lifter tuned for one set,
        // which outranks the prescription in WorkoutSession.restTarget.
        //
        // A new column rather than reusing `restTime`, which sits right beside
        // it and holds the *measured* rest that used to be derived from
        // completion timestamps. Real rows on the phone still carry those
        // values; writing chosen durations into the same column would make the
        // two indistinguishable after the fact.
        migrator.registerMigration("v6_setRestOverride") { db in
            try db.alter(table: "workoutSet") { t in
                t.add(column: "restOverride", .integer)
            }
        }

        // Additive, same reasoning as v2-v6 above.
        //
        // Backs Exercise.suggestions: the movements a program floated for an
        // open slot ("overhead extension," "pushdown"), which used to be prose
        // buried in the exercise's own name.
        migrator.registerMigration("v7_exerciseSuggestions") { db in
            try db.alter(table: "exercise") { t in
                t.add(column: "suggestions", .jsonText)
            }
        }

        // The one non-additive migration, and deliberately so.
        //
        // `matchedSlug` held what the deleted name matcher guessed an exercise
        // probably was. Nothing reads or writes it. Leaving a dead column in
        // place would leave the idea in place too — the next person to see it
        // has to work out that it means nothing, and might reasonably start
        // filling it in again.
        migrator.registerMigration("v8_dropMatchedSlug") { db in
            try db.alter(table: "exercise") { t in
                t.drop(column: "matchedSlug")
            }
        }

        // Additive, same reasoning as v2-v7 above.
        //
        // Backs User.preferredUnit: the unit weights are read and entered in.
        // A display preference, so nothing already stored changes — every
        // logged set keeps the unit it was entered in, and the app converts on
        // the way to the screen.
        //
        // Defaults to lb rather than to the device locale. This is the owner's
        // own training log and it's written in pounds; a locale lookup would be
        // guessing at something already known.
        migrator.registerMigration("v9_userPreferredUnit") { db in
            try db.alter(table: "user") { t in
                t.add(column: "preferredUnit", .text).notNull().defaults(to: "lb")
            }
        }

        // Additive, same reasoning as v2-v7 above.
        //
        // Backs User.exerciseUnits: a sticky per-lift reading preference, so a
        // rack of kg dumbbells stays kg for that exercise instead of being
        // re-set every session.
        //
        // Its own table rather than a column on `exercise`, because it is a
        // property of the *lifter*, not of the catalog entry. The catalog is
        // shared, vendored reference data whose rows are identity claims
        // (`sourceSlug`); writing a personal preference into one would make a
        // re-import either clobber it or have to preserve it. Shaped exactly
        // like `goalMax` — the other per-user, per-exercise setting.
        migrator.registerMigration("v10_exerciseUnitPreference") { db in
            try db.create(table: "exerciseUnitPreference") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("userId", .text).notNull()
                    .references("user", onDelete: .cascade)
                t.column("exerciseId", .integer).notNull()
                    .references("exercise", onDelete: .cascade)
                t.column("unit", .text).notNull()
                t.uniqueKey(["userId", "exerciseId"])
            }
        }

        // Additive, same reasoning as v2-v7 above.
        //
        // Backs WorkoutSet.unit — the most specific level of the unit chain,
        // for the one set done on the kg rack.
        //
        // A column of its own rather than reading the unit off the stored
        // weight: an empty set has no weight and still needs to know what unit
        // it is being entered in. And this is a display preference, so it must
        // not be confused with `weightUnit` beside it, which records what the
        // weight actually was.
        migrator.registerMigration("v11_setUnitOverride") { db in
            try db.alter(table: "workoutSet") { t in
                t.add(column: "unit", .text)
            }
        }

        return migrator
    }
}

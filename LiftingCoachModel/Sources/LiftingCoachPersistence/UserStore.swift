import Foundation
import GRDB
import LiftingCoachModel

private struct UserRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "user"

    var id: String
    var name: String
    var email: String
    var preferredUnit: String
}

private struct BodyWeightRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "bodyWeight"

    var userId: String
    var day: Date
    var value: Double
    var unit: String
}

private struct AchievedMaxRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "achievedMax"

    var userId: String
    var exerciseId: Int
    var value: Double
    var unit: String
    var date: Date
    var notes: String?
}

private struct GoalMaxRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "goalMax"

    var userId: String
    var exerciseId: Int
    var value: Double
    var unit: String
    var dateSet: Date?
}

private struct ExerciseUnitRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exerciseUnitPreference"

    var userId: String
    var exerciseId: Int
    var unit: String
}

private struct ExerciseTrackingRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exerciseTrackingPreference"

    var userId: String
    var exerciseId: Int
    var tracking: String
}

/// Read/write access to the lifter and their tracked metrics.
///
/// Phase 1 is single-user and offline, so there's no sign-in to establish who
/// this is — `localUser()` creates a placeholder on first launch. Cognito
/// replaces that placeholder identity and nothing else: signing in `bind`s the
/// lifter already in this database to an account, rather than fetching a
/// different one. The database stays the system of record.
public struct UserStore: Sendable {
    private let database: AppDatabase
    private let calendar: Calendar

    public init(_ database: AppDatabase, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
    }

    /// Replaces the user and their metrics.
    public func save(_ user: User) throws {
        try database.writer.write { db in
            try UserRow(
                id: user.id.uuidString,
                name: user.name,
                email: user.email,
                preferredUnit: user.preferredUnit.rawValue
            ).save(db)

            // Metrics are replaced wholesale rather than diffed — there are at
            // most a few hundred rows, and a partial update that leaves a stale
            // max behind would quietly mis-prescribe every %1RM set after it.
            try db.execute(sql: "DELETE FROM bodyWeight WHERE userId = ?", arguments: [user.id.uuidString])
            for (day, weight) in user.bodyWeight ?? [:] {
                try BodyWeightRow(
                    userId: user.id.uuidString,
                    day: calendar.startOfDay(for: day),
                    value: weight.value,
                    unit: weight.unit.symbol
                ).insert(db)
            }

            try db.execute(sql: "DELETE FROM achievedMax WHERE userId = ?", arguments: [user.id.uuidString])
            for (exerciseId, history) in user.achievedMaxes ?? [:] {
                // The catalog row has to exist for the foreign key to hold.
                guard try ExerciseRecord.fetchOne(db, key: exerciseId) != nil else { continue }
                for max in history {
                    try AchievedMaxRow(
                        userId: user.id.uuidString,
                        exerciseId: exerciseId,
                        value: max.weight.value,
                        unit: max.weight.unit.symbol,
                        date: max.date,
                        notes: max.notes
                    ).insert(db)
                }
            }

            try db.execute(
                sql: "DELETE FROM exerciseUnitPreference WHERE userId = ?",
                arguments: [user.id.uuidString]
            )
            for (exerciseId, unit) in user.exerciseUnits ?? [:] {
                guard try ExerciseRecord.fetchOne(db, key: exerciseId) != nil else { continue }
                try ExerciseUnitRow(
                    userId: user.id.uuidString,
                    exerciseId: exerciseId,
                    unit: unit.rawValue
                ).insert(db)
            }

            try db.execute(
                sql: "DELETE FROM exerciseTrackingPreference WHERE userId = ?",
                arguments: [user.id.uuidString]
            )
            for (exerciseId, tracking) in user.exerciseTracking ?? [:] {
                guard try ExerciseRecord.fetchOne(db, key: exerciseId) != nil else { continue }
                try ExerciseTrackingRow(
                    userId: user.id.uuidString,
                    exerciseId: exerciseId,
                    tracking: tracking.rawValue
                ).insert(db)
            }

            try db.execute(sql: "DELETE FROM goalMax WHERE userId = ?", arguments: [user.id.uuidString])
            for (exerciseId, goal) in user.goalMaxes ?? [:] {
                guard try ExerciseRecord.fetchOne(db, key: exerciseId) != nil else { continue }
                try GoalMaxRow(
                    userId: user.id.uuidString,
                    exerciseId: exerciseId,
                    value: goal.weight.value,
                    unit: goal.weight.unit.symbol,
                    dateSet: goal.dateSet
                ).insert(db)
            }
        }
    }

    public func fetch(id: UUID) throws -> User? {
        try database.writer.read { db in
            guard let row = try UserRow.fetchOne(db, key: id.uuidString) else { return nil }
            return try hydrate(row, db)
        }
    }

    /// The single local lifter, creating one on first launch if needed.
    public func localUser() throws -> User {
        if let existing = try database.writer.read({ db in
            try UserRow.order(Column("id")).fetchOne(db)
        }) {
            return try database.writer.read { db in try hydrate(existing, db) }
        }

        let user = User(name: "Me", email: "")
        try save(user)
        return user
    }

    /// The Cognito account this database belongs to, or `nil` if it has never
    /// been signed in.
    ///
    /// Read from the database rather than from a token, so it answers offline
    /// and after the session has expired — which is when it matters, since the
    /// question it settles is whose training log is on this phone.
    public func accountBinding(for userId: UUID) throws -> String? {
        try database.writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT cognitoSub FROM user WHERE id = ?",
                arguments: [userId.uuidString]
            )
        }
    }

    /// Binds the local lifter to a Cognito account.
    ///
    /// Binding the same account twice is a no-op — signing back in on a phone
    /// that is already yours should be uneventful.
    ///
    /// Binding a *different* account is refused. The local database is that
    /// first account's training log, and adopting it under a second identity
    /// would upload one person's sessions into another person's snapshot. The
    /// caller's answer is the destructive one: `SnapshotImporter` replaces the
    /// whole file, and the binding arrives with the snapshot rather than being
    /// patched here.
    ///
    /// Signing out never unbinds. It deliberately leaves the note in place: if
    /// it were cleared, the next sign-in as somebody else would find an unbound
    /// database and silently take over the log this refusal exists to protect.
    /// The one release is `releaseDeletedAccount` below.
    public func bind(cognitoSub: String, to userId: UUID) throws {
        try database.writer.write { db in
            let existing = try String.fetchOne(
                db,
                sql: "SELECT cognitoSub FROM user WHERE id = ?",
                arguments: [userId.uuidString]
            )
            if let existing {
                guard existing == cognitoSub else {
                    throw AccountBindingError.boundToAnotherAccount(existing: existing)
                }
                return
            }
            try db.execute(
                sql: "UPDATE user SET cognitoSub = ? WHERE id = ?",
                arguments: [cognitoSub, userId.uuidString]
            )
        }
    }

    /// Releases the binding to an account that **no longer exists**.
    ///
    /// The only way a binding ends. After the lifter deletes their account the
    /// note names nobody — and since every sign-in is refused against it, the
    /// phone would be locked out of the app for good, holding a training log
    /// that is the lifter's own. Cleared, the next sign-in binds this log to
    /// whichever account the lifter makes next, which the deletion screen says
    /// in as many words.
    ///
    /// Conditional on the sub, so a stale call can't release a binding that
    /// has since moved on.
    public func releaseDeletedAccount(_ cognitoSub: String, from userId: UUID) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE user SET cognitoSub = NULL WHERE id = ? AND cognitoSub = ?",
                arguments: [userId.uuidString, cognitoSub]
            )
        }
    }

    /// Sets the unit weights are read and entered in.
    ///
    /// Touches one column and nothing else. Deliberately does **not** rewrite
    /// any stored weight: history keeps the unit it was logged in, and the
    /// preference is applied on the way to the screen (see
    /// `Measurement.expressed(in:)`). Converting the table would round every
    /// row a little and make a display choice destructive.
    public func setPreferredUnit(_ unit: WeightUnit, for userId: UUID) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE user SET preferredUnit = ? WHERE id = ?",
                arguments: [unit.rawValue, userId.uuidString]
            )
        }
    }

    /// Sets (or clears, with `nil`) the unit one lift is read and entered in.
    ///
    /// Sticky across sessions on purpose — a rack of kg dumbbells doesn't
    /// become pounds next Tuesday. Same discipline as `setPreferredUnit`: this
    /// touches one row of preference and rewrites no logged weight. A set
    /// recorded at 100 lb still reads back as 100 lb of iron, shown as 45.4 kg.
    public func setUnit(_ unit: WeightUnit?, forExerciseID exerciseId: Int, for userId: UUID) throws {
        try database.writer.write { db in
            guard let unit else {
                try db.execute(
                    sql: "DELETE FROM exerciseUnitPreference WHERE userId = ? AND exerciseId = ?",
                    arguments: [userId.uuidString, exerciseId]
                )
                return
            }
            try ExerciseUnitRow(
                userId: userId.uuidString,
                exerciseId: exerciseId,
                unit: unit.rawValue
            ).upsert(db)
        }
    }

    /// Sets (or clears, with `nil`) how one exercise is logged. Sticky, and —
    /// like the unit preference above — it changes which fields the tracker
    /// offers from now on and rewrites nothing already logged.
    public func setTracking(
        _ tracking: ExerciseTracking?, forExerciseID exerciseId: Int, for userId: UUID
    ) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM exerciseTrackingPreference WHERE userId = ? AND exerciseId = ?",
                arguments: [userId.uuidString, exerciseId]
            )
            guard let tracking else { return }
            try ExerciseTrackingRow(
                userId: userId.uuidString,
                exerciseId: exerciseId,
                tracking: tracking.rawValue
            ).insert(db)
        }
    }

    /// Records a bodyweight entry without rewriting the rest of the user.
    public func recordBodyWeight(
        _ weight: Measurement<UnitMass>,
        for userId: UUID,
        on day: Date = Date()
    ) throws {
        try database.writer.write { db in
            // upsert, not save: these tables are keyed by an autoincrement rowid,
            // so `save` would insert a duplicate rather than replace the existing
            // (userId, day) row and trip its unique constraint.
            try BodyWeightRow(
                userId: userId.uuidString,
                day: calendar.startOfDay(for: day),
                value: weight.value,
                unit: weight.unit.symbol
            ).upsert(db)
        }
    }

    /// Appends an achieved max — an event, so this never replaces history.
    public func recordAchievedMax(
        _ max: AchievedMax,
        exerciseId: Int,
        for userId: UUID
    ) throws {
        try database.writer.write { db in
            try AchievedMaxRow(
                userId: userId.uuidString,
                exerciseId: exerciseId,
                value: max.weight.value,
                unit: max.weight.unit.symbol,
                date: max.date,
                notes: max.notes
            ).insert(db)
        }
    }

    /// Repairs achieved maxes that the set which earned them contradicts, and
    /// returns how many were retracted.
    ///
    /// An in-app max is recorded at the instant a set is completed, with that
    /// instant as its date, so the two can be matched exactly. A max is
    /// *contradicted* when a set of that exercise was completed at precisely
    /// its timestamp, and no such set now stands as a completed working set at
    /// the max's weight. It claims "this set was 285"; the set says 245.
    ///
    /// **Why this exists:** the tracker used to log a set — and check it for a
    /// max — a moment before the number just typed into it was saved, so
    /// lowering a programmed 285 to 245 and tapping the checkbox recorded 285
    /// as an achieved max that was never lifted. The cause is fixed in
    /// `SuggestingNumberField`; this removes what it left behind, and from
    /// then on catches the same contradiction arising any other way (a set
    /// retyped as a warmup, or corrected downward in History).
    ///
    /// **Retracting alone isn't a repair.** A false max also *suppressed* true
    /// ones: with 100 lb wrongly on record, the set that genuinely reached 100
    /// six minutes later recorded nothing, so deleting the false event would
    /// leave the lift with no max at all. So for each affected exercise, the
    /// maxes that were derived from sets — from the first contradicted one
    /// onward — are dropped and re-derived from the sets as they now stand,
    /// by the same rule the tracker applies (`AchievedMaxUpdate`: completed
    /// working sets, heavier than the best before them).
    ///
    /// **Scoped on purpose.** This is the replay CLAUDE.md lists as an open
    /// decision, applied only where the record is already known to be wrong:
    /// an exercise with no contradicted max is never touched. Imported maxes
    /// (`source` set) and any max with no set at its timestamp — a workout
    /// since deleted — are kept, and count as the best-so-far they are.
    @discardableResult
    public func repairContradictedMaxes(for userId: UUID) throws -> Int {
        try database.writer.write { db in
            // Compared in kilograms with the same 60 g tolerance as
            // `WorkoutSession.sameWeight`, so a set stored in kg still supports
            // a max recorded in lb.
            let tolerance = 0.06
            func kilograms(_ value: String, _ unit: String) -> String {
                "(\(value) * CASE \(unit) WHEN 'lb' THEN 0.45359237 ELSE 1.0 END)"
            }
            let setAtTimestamp = """
                SELECT 1 FROM workoutSet s
                JOIN workoutExercise we ON we.id = s.workoutExerciseId
                WHERE we.exerciseId = achievedMax.exerciseId
                  AND s.timeComplete = achievedMax.date
                """
            let contradicted = try Row.fetchAll(db, sql: """
                SELECT exerciseId, MIN(date) AS earliest, COUNT(*) AS n
                FROM achievedMax
                WHERE userId = ? AND source IS NULL
                  AND EXISTS (\(setAtTimestamp))
                  AND NOT EXISTS (\(setAtTimestamp)
                      AND s.complete = 1 AND s.setType = 'working'
                      AND s.weightValue IS NOT NULL
                      AND ABS(\(kilograms("s.weightValue", "s.weightUnit"))
                            - \(kilograms("achievedMax.value", "achievedMax.unit"))) < \(tolerance))
                GROUP BY exerciseId
                """, arguments: [userId.uuidString])

            var retracted = 0
            for row in contradicted {
                let exerciseId: Int = row["exerciseId"]
                let earliest: Date = row["earliest"]
                retracted += row["n"] as Int

                // Everything set-derived from the first bad event onward goes,
                // not only the contradicted ones: what followed was judged
                // against a best that was wrong.
                try db.execute(sql: """
                    DELETE FROM achievedMax
                    WHERE userId = ? AND exerciseId = ? AND source IS NULL AND date >= ?
                      AND EXISTS (\(setAtTimestamp))
                    """, arguments: [userId.uuidString, exerciseId, earliest])

                // An open-choice slot never records a max (`AchievedMaxUpdate`).
                let isOpenChoice = try Bool.fetchOne(
                    db, sql: "SELECT isOpenChoice FROM exercise WHERE id = ?", arguments: [exerciseId]
                ) ?? false
                guard !isOpenChoice else { continue }

                // What's left — imports, and maxes whose workout is gone — as
                // (date, kg), the standing bests to beat.
                var bests = try Row.fetchAll(db, sql: """
                    SELECT date, \(kilograms("value", "unit")) AS kg FROM achievedMax
                    WHERE userId = ? AND exerciseId = ?
                    """, arguments: [userId.uuidString, exerciseId]
                ).map { (date: $0["date"] as Date, kg: $0["kg"] as Double) }

                let sets = try Row.fetchAll(db, sql: """
                    SELECT s.weightValue, s.weightUnit, s.reps, s.timeComplete,
                           \(kilograms("s.weightValue", "s.weightUnit")) AS kg
                    FROM workoutSet s
                    JOIN workoutExercise we ON we.id = s.workoutExerciseId
                    WHERE we.exerciseId = ? AND s.complete = 1 AND s.setType = 'working'
                      AND s.weightValue IS NOT NULL AND s.timeComplete >= ?
                    ORDER BY s.timeComplete
                    """, arguments: [exerciseId, earliest])

                for set in sets {
                    let completed: Date = set["timeComplete"]
                    let kg: Double = set["kg"]
                    let best = bests.filter { $0.date <= completed }.map(\.kg).max()
                    if let best, kg <= best + tolerance { continue }
                    let reps: Int? = set["reps"]
                    try AchievedMaxRow(
                        userId: userId.uuidString,
                        exerciseId: exerciseId,
                        value: set["weightValue"],
                        unit: set["weightUnit"],
                        date: completed,
                        notes: reps.map { "\($0) rep\($0 == 1 ? "" : "s")" }
                    ).insert(db)
                    bests.append((date: completed, kg: kg))
                }
            }
            return retracted
        }
    }

    /// Sets the goal max for a lift — a setting, so this replaces any previous
    /// goal. upsert, not save: the table is keyed by an autoincrement rowid with
    /// uniqueness on (userId, exerciseId), and save would insert a duplicate.
    public func setGoalMax(
        _ goal: GoalMax,
        exerciseId: Int,
        for userId: UUID
    ) throws {
        try database.writer.write { db in
            try GoalMaxRow(
                userId: userId.uuidString,
                exerciseId: exerciseId,
                value: goal.weight.value,
                unit: goal.weight.unit.symbol,
                dateSet: goal.dateSet
            ).upsert(db)
        }
    }

    private func hydrate(_ row: UserRow, _ db: Database) throws -> User {
        let weights = try BodyWeightRow
            .filter(Column("userId") == row.id)
            .fetchAll(db)
        let achieved = try AchievedMaxRow
            .filter(Column("userId") == row.id)
            .order(Column("date"))
            .fetchAll(db)
        let goals = try GoalMaxRow
            .filter(Column("userId") == row.id)
            .fetchAll(db)
        let units = try ExerciseUnitRow
            .filter(Column("userId") == row.id)
            .fetchAll(db)
        let trackings = try ExerciseTrackingRow
            .filter(Column("userId") == row.id)
            .fetchAll(db)

        var achievedByExercise: [Int: [AchievedMax]] = [:]
        for row in achieved {
            achievedByExercise[row.exerciseId, default: []].append(
                AchievedMax(
                    weight: measurement(value: row.value, symbol: row.unit),
                    date: row.date,
                    notes: row.notes
                )
            )
        }

        return User(
            id: UUID(uuidString: row.id) ?? UUID(),
            name: row.name,
            email: row.email,
            achievedMaxes: achievedByExercise.isEmpty ? nil : achievedByExercise,
            goalMaxes: goals.isEmpty ? nil : Dictionary(
                uniqueKeysWithValues: goals.map {
                    ($0.exerciseId, GoalMax(
                        weight: measurement(value: $0.value, symbol: $0.unit),
                        dateSet: $0.dateSet
                    ))
                }
            ),
            bodyWeight: weights.isEmpty ? nil : Dictionary(
                uniqueKeysWithValues: weights.map {
                    ($0.day, measurement(value: $0.value, symbol: $0.unit))
                }
            ),
            preferredUnit: WeightUnit(rawValue: row.preferredUnit) ?? .pounds,
            exerciseUnits: units.isEmpty ? nil : Dictionary(
                uniqueKeysWithValues: units.compactMap { row in
                    // A stored symbol outside lb/kg isn't a preference this app
                    // can adopt — drop it rather than inventing a default.
                    WeightUnit(rawValue: row.unit).map { (row.exerciseId, $0) }
                }
            ),
            exerciseTracking: trackings.isEmpty ? nil : Dictionary(
                uniqueKeysWithValues: trackings.compactMap { row in
                    ExerciseTracking(rawValue: row.tracking).map { (row.exerciseId, $0) }
                }
            )
        )
    }
}

/// Refused because the database on this device already belongs to someone.
///
/// Not an error state so much as a fork in the sign-in flow: the resolution
/// is a restore, which replaces the whole database, and that is a decision
/// for the lifter rather than something a bind step should take quietly.
public enum AccountBindingError: Error, Equatable {
    case boundToAnotherAccount(existing: String)
}

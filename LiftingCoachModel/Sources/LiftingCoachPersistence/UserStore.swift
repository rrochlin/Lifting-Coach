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

/// Read/write access to the lifter and their tracked metrics.
///
/// Phase 1 is single-user and offline, so there's no sign-in to establish who
/// this is — `localUser()` creates a placeholder on first launch. Cognito lands
/// in phase 2 and will replace the placeholder identity, not the storage.
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
            )
        )
    }
}

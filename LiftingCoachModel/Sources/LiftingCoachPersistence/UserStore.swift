import Foundation
import GRDB
import LiftingCoachModel

private struct UserRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "user"

    var id: String
    var name: String
    var email: String
}

private struct BodyWeightRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "bodyWeight"

    var userId: String
    var day: Date
    var value: Double
    var unit: String
}

private struct MaxLiftRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "maxLift"

    var userId: String
    var exerciseId: Int
    var value: Double
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
                email: user.email
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

            try db.execute(sql: "DELETE FROM maxLift WHERE userId = ?", arguments: [user.id.uuidString])
            for (exerciseId, max) in user.maxLifts ?? [:] {
                // The catalog row has to exist for the foreign key to hold.
                guard try ExerciseRecord.fetchOne(db, key: exerciseId) != nil else { continue }
                try MaxLiftRow(
                    userId: user.id.uuidString,
                    exerciseId: exerciseId,
                    value: max.value,
                    unit: max.unit.symbol
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

    /// Records a 1RM for an exercise without rewriting the rest of the user.
    public func recordMax(
        _ weight: Measurement<UnitMass>,
        exerciseId: Int,
        for userId: UUID
    ) throws {
        try database.writer.write { db in
            try MaxLiftRow(
                userId: userId.uuidString,
                exerciseId: exerciseId,
                value: weight.value,
                unit: weight.unit.symbol
            ).upsert(db)
        }
    }

    private func hydrate(_ row: UserRow, _ db: Database) throws -> User {
        let weights = try BodyWeightRow
            .filter(Column("userId") == row.id)
            .fetchAll(db)
        let maxes = try MaxLiftRow
            .filter(Column("userId") == row.id)
            .fetchAll(db)

        return User(
            id: UUID(uuidString: row.id) ?? UUID(),
            name: row.name,
            email: row.email,
            maxLifts: maxes.isEmpty ? nil : Dictionary(
                uniqueKeysWithValues: maxes.map {
                    ($0.exerciseId, measurement(value: $0.value, symbol: $0.unit))
                }
            ),
            bodyWeight: weights.isEmpty ? nil : Dictionary(
                uniqueKeysWithValues: weights.map {
                    ($0.day, measurement(value: $0.value, symbol: $0.unit))
                }
            )
        )
    }
}

import Foundation
import GRDB
import LiftingCoachModel

// MARK: - Row types

private struct WorkoutRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workout"

    var id: String
    var blockId: String?
    var day: Date?
    var startTime: Date?
    var endTime: Date?
    var notes: String?
    var usernotes: String?
}

private struct WorkoutExerciseRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workoutExercise"

    var id: String
    var workoutId: String
    var exerciseId: Int
    var groupIndex: Int
    var position: Int
    var variant: String?
    var notes: String?
    var usernotes: String?
}

private struct WorkoutSetRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workoutSet"

    var id: String
    var workoutExerciseId: String
    var position: Int
    var reps: Int?
    var weightValue: Double?
    var weightUnit: String?
    var complete: Bool?
    var setType: String?
    var timeComplete: Date?
    var restTime: Int?
    var rpe: Double?
    var notes: String?
    var usernotes: String?
    /// JSON-encoded `PlannedSet`. See the migration for why this is a snapshot
    /// rather than a foreign key.
    var plannedFrom: String?
}

// MARK: - Store

/// Read/write access to logged workouts.
///
/// Saves are whole-workout and atomic: a workout's exercises and sets are
/// replaced together inside one transaction. Partial writes during a live
/// session would be worse than useless — a half-saved workout reads as real data
/// but isn't.
public struct WorkoutStore: Sendable {
    private let database: AppDatabase
    private let calendar: Calendar

    public init(_ database: AppDatabase, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
    }

    // MARK: Writing

    /// Inserts or replaces a workout and everything under it.
    ///
    /// `blockId` is optional so an ad-hoc workout — one logged outside any
    /// programming, which `Ideas.md` names as a requirement — is a first-class
    /// thing to save rather than something needing a fake block.
    public func save(_ workout: Workout, blockId: UUID? = nil) throws {
        try database.writer.write { db in
            // Exercises and sets cascade from the workout row, so deleting first
            // gives a clean replace without diffing. Workouts are small — tens of
            // rows — which makes this cheaper than it looks.
            try WorkoutRow.deleteOne(db, key: workout.id.uuidString)

            try WorkoutRow(
                id: workout.id.uuidString,
                blockId: blockId?.uuidString,
                day: workout.startTime.map { calendar.startOfDay(for: $0) },
                startTime: workout.startTime,
                endTime: workout.endTime,
                notes: workout.notes,
                usernotes: workout.usernotes
            ).insert(db)

            for (groupIndex, group) in (workout.exercises ?? []).enumerated() {
                for (position, exercise) in group.enumerated() {
                    // The catalog row must exist for the foreign key to hold. An
                    // exercise added mid-workout may not be in the catalog yet.
                    try ExerciseRecord(exercise.exercise).save(db)

                    try WorkoutExerciseRow(
                        id: exercise.id.uuidString,
                        workoutId: workout.id.uuidString,
                        exerciseId: exercise.exercise.id,
                        groupIndex: groupIndex,
                        position: position,
                        variant: exercise.variant,
                        notes: exercise.notes,
                        usernotes: exercise.usernotes
                    ).insert(db)

                    for (setPosition, set) in (exercise.sets ?? []).enumerated() {
                        try WorkoutSetRow(
                            id: set.id.uuidString,
                            workoutExerciseId: exercise.id.uuidString,
                            position: setPosition,
                            reps: set.reps,
                            weightValue: set.weight?.value,
                            weightUnit: set.weight?.unit.symbol,
                            complete: set.complete,
                            setType: set.type?.rawValue,
                            timeComplete: set.timeComplete,
                            restTime: set.restTime,
                            rpe: set.rpe.map(Double.init),
                            notes: set.notes,
                            usernotes: set.usernotes,
                            plannedFrom: try set.plannedFrom.map(encodePlannedSet)
                        ).insert(db)
                    }
                }
            }
        }
    }

    public func delete(id: UUID) throws {
        _ = try database.writer.write { db in
            try WorkoutRow.deleteOne(db, key: id.uuidString)
        }
    }

    // MARK: Reading

    public func fetch(id: UUID) throws -> Workout? {
        try database.writer.read { db in
            guard let row = try WorkoutRow.fetchOne(db, key: id.uuidString) else { return nil }
            return try hydrate(row, db)
        }
    }

    /// Workouts logged on a calendar day — what the History calendar reads.
    public func fetch(on day: Date) throws -> [Workout] {
        let start = calendar.startOfDay(for: day)
        return try database.writer.read { db in
            try WorkoutRow
                .filter(Column("day") == start)
                .order(Column("startTime"))
                .fetchAll(db)
                .map { try hydrate($0, db) }
        }
    }

    /// Workouts overlapping a date range, oldest first.
    public func fetch(from start: Date, to end: Date) throws -> [Workout] {
        let lower = calendar.startOfDay(for: start)
        let upper = calendar.startOfDay(for: end)
        return try database.writer.read { db in
            try WorkoutRow
                .filter(Column("day") >= lower && Column("day") <= upper)
                .order(Column("startTime"))
                .fetchAll(db)
                .map { try hydrate($0, db) }
        }
    }

    /// The workout that was started but never ended, if there is one.
    ///
    /// This is what lets the tracker survive the app being killed mid-session —
    /// the common case when the phone locks in a gym bag.
    public func fetchInProgress() throws -> Workout? {
        try database.writer.read { db in
            guard let row = try WorkoutRow
                .filter(Column("startTime") != nil && Column("endTime") == nil)
                .order(Column("startTime").desc)
                .fetchOne(db)
            else { return nil }
            return try hydrate(row, db)
        }
    }

    // MARK: Hydration

    private func hydrate(_ row: WorkoutRow, _ db: Database) throws -> Workout {
        let exerciseRows = try WorkoutExerciseRow
            .filter(Column("workoutId") == row.id)
            .order(Column("groupIndex"), Column("position"))
            .fetchAll(db)

        var groups: [[WorkoutExercise]] = []
        for exerciseRow in exerciseRows {
            guard let catalog = try ExerciseRecord.fetchOne(db, key: exerciseRow.exerciseId)?.domain else {
                continue
            }

            let sets = try WorkoutSetRow
                .filter(Column("workoutExerciseId") == exerciseRow.id)
                .order(Column("position"))
                .fetchAll(db)
                .map(decodeSet)

            let exercise = WorkoutExercise(
                id: UUID(uuidString: exerciseRow.id) ?? UUID(),
                exercise: catalog,
                sets: sets,
                variant: exerciseRow.variant,
                notes: exerciseRow.notes,
                usernotes: exerciseRow.usernotes
            )

            // Rows arrive ordered by groupIndex, so a new index starts a new
            // superset group.
            if groups.count == exerciseRow.groupIndex + 1 {
                groups[exerciseRow.groupIndex].append(exercise)
            } else {
                groups.append([exercise])
            }
        }

        return Workout(
            id: UUID(uuidString: row.id) ?? UUID(),
            exercises: groups,
            startTime: row.startTime,
            endTime: row.endTime,
            notes: row.notes,
            usernotes: row.usernotes
        )
    }

    private func decodeSet(_ row: WorkoutSetRow) -> WorkoutSet {
        WorkoutSet(
            id: UUID(uuidString: row.id) ?? UUID(),
            reps: row.reps,
            weight: optionalMeasurement(value: row.weightValue, symbol: row.weightUnit),
            complete: row.complete,
            type: row.setType.flatMap(SetType.init(rawValue:)),
            timeComplete: row.timeComplete,
            restTime: row.restTime,
            rpe: row.rpe.map(Float.init),
            notes: row.notes,
            usernotes: row.usernotes,
            plannedFrom: row.plannedFrom.flatMap(decodePlannedSet)
        )
    }
}

// MARK: - Encoding helpers

private let plannedSetEncoder = JSONEncoder()
private let plannedSetDecoder = JSONDecoder()

private func encodePlannedSet(_ set: PlannedSet) throws -> String {
    String(decoding: try plannedSetEncoder.encode(set), as: UTF8.self)
}

private func decodePlannedSet(_ json: String) -> PlannedSet? {
    // A prescription that fails to decode shouldn't take the logged set down with
    // it — what was lifted matters more than what was asked for.
    try? plannedSetDecoder.decode(PlannedSet.self, from: Data(json.utf8))
}


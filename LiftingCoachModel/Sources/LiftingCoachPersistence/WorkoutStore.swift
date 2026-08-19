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
    /// `nil` for a workout logged in this app; otherwise the translation that
    /// produced it. See `Workout.source`.
    var source: String?
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

/// Internal rather than private: `ExerciseStatsStore` reads sets straight from
/// the log for its per-exercise history, and a second hand-rolled decoder there
/// would be one more place for the mapping to drift.
struct WorkoutSetRow: Codable, FetchableRecord, PersistableRecord {
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
    var restOverride: Int?
    /// Display/entry unit override for this set. Distinct from `weightUnit`
    /// above, which records what the logged weight actually is.
    var unit: String?
    /// Time-based work: how long the set itself took. Nothing to do with the
    /// two rest columns above, which measure the gap between sets.
    var durationSeconds: Double?
    var distanceValue: Double?
    var distanceUnit: String?
    var rpe: Double?
    var notes: String?
    var usernotes: String?
    /// JSON-encoded `PlannedSet`. See the migration for why this is a snapshot
    /// rather than a foreign key.
    var plannedFrom: String?

    var domain: WorkoutSet {
        WorkoutSet(
            id: UUID(uuidString: id) ?? UUID(),
            reps: reps,
            weight: optionalMeasurement(value: weightValue, symbol: weightUnit),
            complete: complete,
            type: setType.flatMap(SetType.init(rawValue:)),
            timeComplete: timeComplete,
            restTime: restTime,
            restOverride: restOverride,
            unit: unit.flatMap(WeightUnit.init(rawValue:)),
            duration: optionalDuration(seconds: durationSeconds),
            distance: optionalDistance(value: distanceValue, symbol: distanceUnit),
            rpe: rpe.map(Float.init),
            notes: notes,
            usernotes: usernotes,
            plannedFrom: plannedFrom.flatMap(decodePlannedSet)
        )
    }
}

// MARK: - Summary

/// Enough of a logged workout to draw one row of history, and nothing more.
///
/// Deliberately not a `Workout` with some fields left empty: a half-filled
/// domain value invites a caller to reach for `allSets` and get a wrong answer
/// silently. This type simply doesn't have sets, so the compiler says so.
public struct WorkoutSummary: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var startTime: Date?
    public var endTime: Date?
    /// The workout's own title, where it has one ("Legs", "Full Body 1").
    public var notes: String?
    /// `nil` for a workout logged in this app. See `Workout.source`.
    public var source: String?
    /// Exercise display names in the order they were performed.
    public var exerciseNames: [String]
    public var completedSetCount: Int

    public init(
        id: UUID,
        startTime: Date? = nil,
        endTime: Date? = nil,
        notes: String? = nil,
        source: String? = nil,
        exerciseNames: [String] = [],
        completedSetCount: Int = 0
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.notes = notes
        self.source = source
        self.exerciseNames = exerciseNames
        self.completedSetCount = completedSetCount
    }

    /// How long the session took, when both ends are known.
    public var duration: TimeInterval? {
        guard let startTime, let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }
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
                usernotes: workout.usernotes,
                source: workout.source
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
                            restOverride: set.restOverride,
                            unit: set.unit?.rawValue,
                            durationSeconds: set.duration
                                .map { $0.converted(to: .seconds).value },
                            distanceValue: set.distance?.value,
                            distanceUnit: set.distance?.unit.symbol,
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

    /// Rewrites a workout already in the log, keeping its block association.
    ///
    /// `save` takes `blockId` as a parameter because the caller is the only one
    /// who knows it — `Workout` has no such field, and `hydrate` therefore
    /// can't return one. That's correct for logging a *new* workout and wrong
    /// for correcting an old one: an edit round-trips through `fetch`, so
    /// calling `save` on the result would write `blockId = NULL` and quietly
    /// detach the workout from the block it was performed in.
    ///
    /// Nothing writes `blockId` today (the tracker saves without one, and
    /// adherence joins by date), so this is not a live bug — it is the one line
    /// that stops editing history from becoming one the moment something does.
    public func update(_ workout: Workout) throws {
        let existingBlockId = try database.writer.read { db in
            try WorkoutRow.fetchOne(db, key: workout.id.uuidString)?.blockId
        }
        try save(workout, blockId: existingBlockId.flatMap(UUID.init(uuidString:)))
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

    /// A page of finished workouts, newest first, without hydrating any of them.
    ///
    /// `fetch(from:to:)` builds whole `Workout` values — a query per exercise, a
    /// query per set, and a catalog lookup for each — which is right when
    /// something is going to read the sets and ruinous when it isn't. The
    /// History list renders a date, a few names and a count; against five years
    /// of imported history that was several thousand queries to draw a screen
    /// nobody had scrolled yet.
    ///
    /// Three bounded queries per page instead: the rows, then the names and the
    /// counts for exactly those ids. Names are fetched separately rather than
    /// with `group_concat` because ordering inside that aggregate needs a SQLite
    /// newer than the deployment target can promise, and the order exercises
    /// were performed in is the whole point of showing them.
    ///
    /// - Parameter before: return workouts started strictly before this instant.
    ///   Pass the last summary's `startTime` to page backwards.
    public func fetchSummaries(limit: Int, before: Date? = nil) throws -> [WorkoutSummary] {
        try database.writer.read { db in
            var request = WorkoutRow
                // History is what was finished. The in-progress session belongs
                // to the tracker, and listing it here would offer a way to open
                // a workout that is still being written.
                .filter(Column("endTime") != nil)
                .order(Column("startTime").desc)
                .limit(limit)
            if let before {
                request = request.filter(Column("startTime") < before)
            }
            let rows = try request.fetchAll(db)
            guard !rows.isEmpty else { return [] }

            let ids = rows.map(\.id)
            let placeholders = databaseQuestionMarks(count: ids.count)

            var names: [String: [String]] = [:]
            let nameRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT we.workoutId AS workoutId,
                           COALESCE(NULLIF(we.variant, ''), e.name) AS name
                    FROM workoutExercise we
                    JOIN exercise e ON e.id = we.exerciseId
                    WHERE we.workoutId IN (\(placeholders))
                    ORDER BY we.workoutId, we.groupIndex, we.position
                    """,
                arguments: StatementArguments(ids)
            )
            for row in nameRows {
                names[row["workoutId"], default: []].append(row["name"])
            }

            var counts: [String: Int] = [:]
            let countRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT we.workoutId AS workoutId, COUNT(*) AS n
                    FROM workoutSet s
                    JOIN workoutExercise we ON we.id = s.workoutExerciseId
                    WHERE we.workoutId IN (\(placeholders)) AND s.complete = 1
                    GROUP BY we.workoutId
                    """,
                arguments: StatementArguments(ids)
            )
            for row in countRows {
                counts[row["workoutId"]] = row["n"]
            }

            return rows.map { row in
                WorkoutSummary(
                    id: UUID(uuidString: row.id) ?? UUID(),
                    startTime: row.startTime,
                    endTime: row.endTime,
                    notes: row.notes,
                    source: row.source,
                    exerciseNames: names[row.id] ?? [],
                    completedSetCount: counts[row.id] ?? 0
                )
            }
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
                .map(\.domain)

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
            usernotes: row.usernotes,
            source: row.source
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


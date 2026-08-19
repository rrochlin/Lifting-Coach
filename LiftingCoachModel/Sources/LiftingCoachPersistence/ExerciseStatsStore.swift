import Foundation
import GRDB
import LiftingCoachModel

// MARK: - Domain

/// What the lifter has actually done with one exercise.
///
/// Everything here is computed from the log; none of it is entered. See
/// `ExerciseStatsStore` for why it's nonetheless persisted.
public struct ExerciseStats: Hashable, Sendable {
    /// Completed workouts containing this lift — not sets, and not sessions
    /// abandoned partway through.
    public var sessionCount: Int
    public var setCount: Int
    public var lastPerformed: Date?
    /// The heaviest logged **working** set. Warmups and drops are excluded on
    /// purpose: a ramp-up single and a back-off aren't attempts at a limit, so
    /// including them would make "heaviest" mean nothing in particular. Same
    /// reasoning `AchievedMaxUpdate` already applies.
    public var heaviestWorkingSet: Measurement<UnitMass>?

    public init(
        sessionCount: Int,
        setCount: Int,
        lastPerformed: Date? = nil,
        heaviestWorkingSet: Measurement<UnitMass>? = nil
    ) {
        self.sessionCount = sessionCount
        self.setCount = setCount
        self.lastPerformed = lastPerformed
        self.heaviestWorkingSet = heaviestWorkingSet
    }
}

/// One past performance of an exercise — a day, and what was logged that day.
public struct ExerciseSessionRecord: Hashable, Sendable, Identifiable {
    /// The `WorkoutExercise` id, which is what makes this row unique even when
    /// a program prescribes the same lift twice in one session.
    public var id: UUID
    public var workoutID: UUID
    public var date: Date
    /// The plan's own wording that day ("heavy, paused"), so history stays
    /// readable without the plan in hand.
    public var variant: String?
    public var sets: [WorkoutSet]

    public init(
        id: UUID,
        workoutID: UUID,
        date: Date,
        variant: String? = nil,
        sets: [WorkoutSet]
    ) {
        self.id = id
        self.workoutID = workoutID
        self.date = date
        self.variant = variant
        self.sets = sets
    }
}

// MARK: - Store

/// Per-lift history: how often, how recently, how heavy, and what happened.
///
/// **The summary table is derived and rebuilt, never incremented.** That
/// distinction is the whole reason it's safe to keep a second copy of something
/// the log already knows:
///
/// - A counter maintained at write time has to be adjusted correctly by every
///   path that touches the log — finishing a workout (which drops incomplete
///   sets), discarding one, deleting a set, editing history, importing. Miss one
///   and the number is wrong permanently, with nothing able to detect it.
/// - `rebuild(for:)` recomputes every row from the log in one statement, so the
///   worst state this table can reach is *stale*. It cannot disagree with the
///   log, because the log is what it's computed from, and dropping it is always
///   a valid repair.
///
/// `rebuild` is therefore the only writer, and it runs on the few events that
/// change history: finishing a workout, deleting one, and finishing an import.
/// Deliberately not on every logged set — mid-workout these numbers don't need
/// to be live, and an aggregate in the hot path of checking off a set is a cost
/// paid dozens of times per session for nothing.
public struct ExerciseStatsStore: Sendable {
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    // MARK: Rebuilding

    /// Recomputes every stats row for a lifter from the log.
    ///
    /// One `DELETE` plus one `INSERT … SELECT`, in a transaction, so a reader
    /// never sees the table half-built.
    ///
    /// Only completed workouts count (`endTime IS NOT NULL`). An in-progress
    /// session isn't history yet, and counting it would also make the suggestion
    /// in the tracker propose the very set the lifter is looking at.
    public func rebuild(for userId: UUID) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM exerciseStats WHERE userId = ?",
                arguments: [userId.uuidString]
            )
            try db.execute(sql: """
                INSERT INTO exerciseStats
                    (userId, exerciseId, sessionCount, setCount, lastPerformed,
                     heaviestValue, heaviestUnit)
                SELECT
                    :userId,
                    we.exerciseId,
                    COUNT(DISTINCT we.workoutId),
                    COUNT(ws.id),
                    MAX(w.startTime),
                    -- Heaviest working set, and the unit it was logged in.
                    -- Compared in kilograms so a 100 kg set outranks a 200 lb
                    -- one, but reported in whatever unit it was entered in —
                    -- normalizing storage would round what the lifter typed.
                    (SELECT s2.weightValue FROM workoutSet s2
                       JOIN workoutExercise we2 ON we2.id = s2.workoutExerciseId
                       JOIN workout w2 ON w2.id = we2.workoutId
                      WHERE we2.exerciseId = we.exerciseId
                        AND w2.endTime IS NOT NULL
                        AND s2.complete = 1
                        AND s2.setType = 'working'
                        AND s2.weightValue IS NOT NULL
                      ORDER BY s2.weightValue *
                          (CASE s2.weightUnit WHEN 'kg' THEN 1.0 ELSE 0.45359237 END) DESC
                      LIMIT 1),
                    (SELECT s2.weightUnit FROM workoutSet s2
                       JOIN workoutExercise we2 ON we2.id = s2.workoutExerciseId
                       JOIN workout w2 ON w2.id = we2.workoutId
                      WHERE we2.exerciseId = we.exerciseId
                        AND w2.endTime IS NOT NULL
                        AND s2.complete = 1
                        AND s2.setType = 'working'
                        AND s2.weightValue IS NOT NULL
                      ORDER BY s2.weightValue *
                          (CASE s2.weightUnit WHEN 'kg' THEN 1.0 ELSE 0.45359237 END) DESC
                      LIMIT 1)
                FROM workoutExercise we
                JOIN workout w ON w.id = we.workoutId
                LEFT JOIN workoutSet ws
                       ON ws.workoutExerciseId = we.id AND ws.complete = 1
                WHERE w.endTime IS NOT NULL
                GROUP BY we.exerciseId
                """, arguments: ["userId": userId.uuidString])
        }
    }

    // MARK: Reading

    /// Every lift the user has on record, keyed by `Exercise.id`.
    ///
    /// Returned whole rather than queried per exercise: the picker needs all of
    /// them at once to sort by, and 150-odd rows is one cheap read.
    public func stats(for userId: UUID) throws -> [Int: ExerciseStats] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT exerciseId, sessionCount, setCount, lastPerformed,
                       heaviestValue, heaviestUnit
                  FROM exerciseStats WHERE userId = ?
                """, arguments: [userId.uuidString])
            .reduce(into: [Int: ExerciseStats]()) { result, row in
                result[row["exerciseId"]] = ExerciseStats(
                    sessionCount: row["sessionCount"],
                    setCount: row["setCount"],
                    lastPerformed: row["lastPerformed"],
                    heaviestWorkingSet: optionalMeasurement(
                        value: row["heaviestValue"], symbol: row["heaviestUnit"]
                    )
                )
            }
        }
    }

    /// Past performances of one exercise, newest first.
    ///
    /// Read straight from the log rather than from the summary: this needs the
    /// individual sets, which is exactly what an aggregate has thrown away.
    public func sessions(forExerciseID exerciseID: Int, limit: Int = 10) throws -> [ExerciseSessionRecord] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT we.id AS exerciseRowId, we.workoutId, we.variant, w.startTime
                  FROM workoutExercise we
                  JOIN workout w ON w.id = we.workoutId
                 WHERE we.exerciseId = ? AND w.endTime IS NOT NULL
                 ORDER BY w.startTime DESC
                 LIMIT ?
                """, arguments: [exerciseID, limit])

            return try rows.compactMap { row in
                let id: String = row["exerciseRowId"]
                guard let date: Date = row["startTime"] else { return nil }
                let sets = try WorkoutSetRow
                    .filter(Column("workoutExerciseId") == id)
                    .order(Column("position"))
                    .fetchAll(db)
                    .map(\.domain)
                return ExerciseSessionRecord(
                    id: UUID(uuidString: id) ?? UUID(),
                    workoutID: UUID(uuidString: row["workoutId"]) ?? UUID(),
                    date: date,
                    variant: row["variant"],
                    sets: sets
                )
            }
        }
    }

    /// The most recent completed performance of a lift — what the tracker's
    /// set suggestions are drawn from.
    public func lastSession(forExerciseID exerciseID: Int) throws -> ExerciseSessionRecord? {
        try sessions(forExerciseID: exerciseID, limit: 1).first
    }
}

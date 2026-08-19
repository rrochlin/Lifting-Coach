import Foundation
import GRDB
import LiftingCoachModel

// MARK: - Row types

private struct BlockRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "block"

    var id: String
    var userId: String
    var startDate: Date?
    var endDate: Date?
    var notes: String?
    var journal: String?
}

private struct BlockDefaultRestRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "blockDefaultRest"

    var blockId: String
    var setType: String
    var seconds: Int
}

private struct PlannedWorkoutRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "plannedWorkout"

    var id: String
    var blockId: String
    var date: Date?
    var notes: String?
    var skippedAt: Date?
}

private struct PlannedExerciseRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "plannedExercise"

    var id: String
    var plannedWorkoutId: String
    var exerciseId: Int
    var groupIndex: Int
    var position: Int
    var effortRPE: Double?
    var variant: String?
    var notes: String?
}

private struct PlannedSetRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "plannedSet"

    var id: String
    var plannedExerciseId: String
    var position: Int
    var reps: Int?
    var setType: String?
    var loadKind: String?
    var loadValue: Double?
    var loadUnit: String?
    var loadMaxRef: String?
    var effortRPE: Double?
    var restTime: Int?
    var notes: String?
}

// MARK: - Store

/// Read/write access to programming: training blocks and the workouts planned
/// inside them.
///
/// Loaded blocks come back with `program` populated and `workouts` left `nil` —
/// the planned side and the logged side are fetched separately so opening the
/// planner doesn't drag in every workout ever logged. Use
/// `attachingLoggedWorkouts(to:using:)` when both are actually needed, which is
/// really only adherence.
public struct PlanStore: Sendable {
    private let database: AppDatabase
    private let calendar: Calendar

    public init(_ database: AppDatabase, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
    }

    // MARK: Writing

    /// Inserts or replaces a block and its whole program.
    public func save(_ block: WorkoutBlock, userId: UUID) throws {
        try database.writer.write { db in
            // Everything below the block cascades, so a delete-then-insert is a
            // clean replace. Editing a plan can't reach logged workouts: those
            // reference the block with ON DELETE SET NULL, and a logged set's
            // prescription is a snapshot rather than a reference.
            try BlockRow.deleteOne(db, key: block.id.uuidString)

            try BlockRow(
                id: block.id.uuidString,
                userId: userId.uuidString,
                startDate: block.startDate.map { calendar.startOfDay(for: $0) },
                endDate: block.endDate.map { calendar.startOfDay(for: $0) },
                notes: block.notes,
                journal: block.journal
            ).insert(db)

            for (type, seconds) in block.defaultRestTimes ?? [:] {
                try BlockDefaultRestRow(
                    blockId: block.id.uuidString,
                    setType: type.rawValue,
                    seconds: seconds
                ).insert(db)
            }

            for (day, planned) in block.program ?? [:] {
                for workout in planned {
                    try insert(workout, day: day, blockId: block.id, db)
                }
            }
        }
    }

    /// Inserts or replaces a single planned workout inside an existing block.
    ///
    /// Editing one day of a program shouldn't mean rewriting the whole block —
    /// `Workout Planner.md` is explicit that a change in week 3 must not disturb
    /// weeks 1 and 2.
    public func save(_ workout: PlannedWorkout, in blockId: UUID) throws {
        try database.writer.write { db in
            try PlannedWorkoutRow.deleteOne(db, key: workout.id.uuidString)
            try insert(
                workout,
                day: workout.date ?? Date(timeIntervalSince1970: 0),
                blockId: blockId,
                db
            )
        }
    }

    /// Writes a block's own settings — its dates, name, journal and rest
    /// defaults — plus the dates of the days it programs.
    ///
    /// Deliberately narrow, and that narrowness is the point. `save(_:userId:)`
    /// replaces a block by deleting it and reinserting the whole graph, which
    /// is right when the program itself is what's being written. Changing a
    /// start date is a different thing: the prescriptions aren't being edited,
    /// they're being *moved*, and putting every set in a 12-week block through
    /// a delete on the way to changing one date is a risk taken for nothing.
    /// Nothing here touches `plannedExercise` or `plannedSet`, so this cannot
    /// lose a prescription however it fails.
    ///
    /// Days move by whatever `block.program` says they are now — see
    /// `WorkoutBlock.rescheduled(to:calendar:)`, which is where the shift is
    /// actually computed. A block whose days haven't moved simply rewrites the
    /// same dates.
    public func updateSettings(_ block: WorkoutBlock, userId: UUID) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE block
                    SET startDate = ?, endDate = ?, notes = ?, journal = ?
                    WHERE id = ? AND userId = ?
                    """,
                arguments: [
                    block.startDate.map { calendar.startOfDay(for: $0) },
                    block.endDate.map { calendar.startOfDay(for: $0) },
                    block.notes,
                    block.journal,
                    block.id.uuidString,
                    userId.uuidString,
                ]
            )

            // Replaced wholesale rather than merged: a rest default the lifter
            // cleared has to disappear, and an UPSERT per entry would leave it
            // behind.
            try db.execute(
                sql: "DELETE FROM blockDefaultRest WHERE blockId = ?",
                arguments: [block.id.uuidString]
            )
            for (type, seconds) in block.defaultRestTimes ?? [:] {
                try BlockDefaultRestRow(
                    blockId: block.id.uuidString,
                    setType: type.rawValue,
                    seconds: seconds
                ).insert(db)
            }

            for (day, planned) in block.program ?? [:] {
                let date = calendar.startOfDay(for: day)
                for workout in planned {
                    try db.execute(
                        sql: "UPDATE plannedWorkout SET date = ? WHERE id = ?",
                        arguments: [date, workout.id.uuidString]
                    )
                }
            }
        }
    }

    public func deleteBlock(id: UUID) throws {
        _ = try database.writer.write { db in
            try BlockRow.deleteOne(db, key: id.uuidString)
        }
    }

    public func deletePlannedWorkout(id: UUID) throws {
        _ = try database.writer.write { db in
            try PlannedWorkoutRow.deleteOne(db, key: id.uuidString)
        }
    }

    private func insert(
        _ workout: PlannedWorkout,
        day: Date,
        blockId: UUID,
        _ db: Database
    ) throws {
        try PlannedWorkoutRow(
            id: workout.id.uuidString,
            blockId: blockId.uuidString,
            date: calendar.startOfDay(for: workout.date ?? day),
            notes: workout.notes,
            skippedAt: workout.skippedAt
        ).insert(db)

        for (groupIndex, group) in (workout.exercises ?? []).enumerated() {
            for (position, exercise) in group.enumerated() {
                try ExerciseRecord(exercise.exercise).save(db)

                try PlannedExerciseRow(
                    id: exercise.id.uuidString,
                    plannedWorkoutId: workout.id.uuidString,
                    exerciseId: exercise.exercise.id,
                    groupIndex: groupIndex,
                    position: position,
                    effortRPE: exercise.effort.map { Double($0.rpe) },
                    variant: exercise.variant,
                    notes: exercise.notes
                ).insert(db)

                for (setPosition, set) in (exercise.sets ?? []).enumerated() {
                    let load = encode(set.load)
                    try PlannedSetRow(
                        id: set.id.uuidString,
                        plannedExerciseId: exercise.id.uuidString,
                        position: setPosition,
                        reps: set.reps,
                        setType: set.type?.rawValue,
                        loadKind: load.kind,
                        loadValue: load.value,
                        loadUnit: load.unit,
                        loadMaxRef: load.maxRef,
                        effortRPE: set.effort.map { Double($0.rpe) },
                        restTime: set.restTime,
                        notes: set.notes
                    ).insert(db)
                }
            }
        }
    }

    // MARK: Reading

    public func fetchBlock(id: UUID) throws -> WorkoutBlock? {
        try database.writer.read { db in
            guard let row = try BlockRow.fetchOne(db, key: id.uuidString) else { return nil }
            return try hydrate(row, db)
        }
    }

    /// The lifter's whole plan, oldest block first.
    public func fetchPlan(userId: UUID) throws -> WorkoutPlan {
        let blocks = try database.writer.read { db in
            try BlockRow
                .filter(Column("userId") == userId.uuidString)
                .order(Column("startDate"))
                .fetchAll(db)
                .map { try hydrate($0, db) }
        }
        return WorkoutPlan(blocks: blocks.isEmpty ? nil : blocks)
    }

    /// Workouts programmed for a calendar day, across every block.
    public func fetchPlanned(on day: Date) throws -> [PlannedWorkout] {
        let start = calendar.startOfDay(for: day)
        return try database.writer.read { db in
            try PlannedWorkoutRow
                .filter(Column("date") == start)
                .fetchAll(db)
                .map { try hydrate($0, db) }
        }
    }

    /// Workouts programmed within a date range (inclusive), across every block
    /// — backs the Tracker's week view, so a lifter sees more than just today
    /// and can start or skip an adjacent day.
    public func fetchPlanned(from start: Date, to end: Date) throws -> [PlannedWorkout] {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        return try database.writer.read { db in
            try PlannedWorkoutRow
                .filter(Column("date") >= startDay && Column("date") <= endDay)
                .order(Column("date"))
                .fetchAll(db)
                .map { try hydrate($0, db) }
        }
    }

    /// Marks a planned workout skipped without deleting it — a narrow direct
    /// update rather than routing through `save(_:in:)`, since flipping one
    /// column shouldn't require reconstructing the whole nested plan graph.
    public func markSkipped(workoutID: UUID, at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE plannedWorkout SET skippedAt = ? WHERE id = ?",
                arguments: [date, workoutID.uuidString]
            )
        }
    }

    /// Reverses a skip.
    public func unmarkSkipped(workoutID: UUID) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE plannedWorkout SET skippedAt = NULL WHERE id = ?",
                arguments: [workoutID.uuidString]
            )
        }
    }

    /// Fills in a block's logged `workouts` alongside its `program`.
    ///
    /// Separate from the block fetch because it's only needed for adherence —
    /// rendering the planner itself doesn't require workout history.
    public func attachingLoggedWorkouts(
        to block: WorkoutBlock,
        using workouts: WorkoutStore
    ) throws -> WorkoutBlock {
        guard let start = block.startDate else { return block }
        // A block that has run past its planned end still accrues workouts, so
        // read through to today rather than stopping at endDate.
        let end = max(block.endDate ?? start, Date())

        var block = block
        block.workouts = Dictionary(
            grouping: try workouts.fetch(from: start, to: end).filter { $0.startTime != nil },
            by: { calendar.startOfDay(for: $0.startTime!) }
        )
        return block
    }

    // MARK: Hydration

    private func hydrate(_ row: BlockRow, _ db: Database) throws -> WorkoutBlock {
        let rests = try BlockDefaultRestRow
            .filter(Column("blockId") == row.id)
            .fetchAll(db)

        let plannedRows = try PlannedWorkoutRow
            .filter(Column("blockId") == row.id)
            .order(Column("date"))
            .fetchAll(db)

        var program: [Date: [PlannedWorkout]] = [:]
        for plannedRow in plannedRows {
            let workout = try hydrate(plannedRow, db)
            guard let date = workout.date else { continue }
            program[date, default: []].append(workout)
        }

        return WorkoutBlock(
            id: UUID(uuidString: row.id) ?? UUID(),
            workouts: nil,
            program: program.isEmpty ? nil : program,
            startDate: row.startDate,
            endDate: row.endDate,
            notes: row.notes,
            journal: row.journal,
            defaultRestTimes: rests.isEmpty ? nil : Dictionary(
                uniqueKeysWithValues: rests.compactMap { rest in
                    SetType(rawValue: rest.setType).map { ($0, rest.seconds) }
                }
            )
        )
    }

    private func hydrate(_ row: PlannedWorkoutRow, _ db: Database) throws -> PlannedWorkout {
        let exerciseRows = try PlannedExerciseRow
            .filter(Column("plannedWorkoutId") == row.id)
            .order(Column("groupIndex"), Column("position"))
            .fetchAll(db)

        var groups: [[PlannedExercise]] = []
        for exerciseRow in exerciseRows {
            guard let catalog = try ExerciseRecord.fetchOne(db, key: exerciseRow.exerciseId)?.domain else {
                continue
            }

            let sets = try PlannedSetRow
                .filter(Column("plannedExerciseId") == exerciseRow.id)
                .order(Column("position"))
                .fetchAll(db)
                .map(decode)

            let exercise = PlannedExercise(
                id: UUID(uuidString: exerciseRow.id) ?? UUID(),
                exercise: catalog,
                sets: sets,
                effort: exerciseRow.effortRPE.map { EffortTarget(rpe: Float($0)) },
                variant: exerciseRow.variant,
                notes: exerciseRow.notes
            )

            // Rows arrive ordered by groupIndex, so a new index opens a new
            // superset group.
            if groups.count == exerciseRow.groupIndex + 1 {
                groups[exerciseRow.groupIndex].append(exercise)
            } else {
                groups.append([exercise])
            }
        }

        return PlannedWorkout(
            id: UUID(uuidString: row.id) ?? UUID(),
            date: row.date,
            exercises: groups.isEmpty ? nil : groups,
            notes: row.notes,
            skippedAt: row.skippedAt
        )
    }

    private func decode(_ row: PlannedSetRow) -> PlannedSet {
        PlannedSet(
            id: UUID(uuidString: row.id) ?? UUID(),
            reps: row.reps,
            type: row.setType.flatMap(SetType.init(rawValue:)),
            load: decodeLoad(
                kind: row.loadKind,
                value: row.loadValue,
                unit: row.loadUnit,
                maxRef: row.loadMaxRef
            ),
            effort: row.effortRPE.map { EffortTarget(rpe: Float($0)) },
            restTime: row.restTime,
            notes: row.notes
        )
    }
}

// MARK: - Load encoding

/// `LoadPrescription` flattened into columns.
///
/// Stored as discriminator + value rather than as JSON so the planner can filter
/// and aggregate on it in SQL later — "every set programmed above 85%" is a query
/// this app will eventually want, and it's the reason this doesn't reuse the
/// snapshot approach that `workoutSet.plannedFrom` uses.
private func encode(
    _ load: LoadPrescription?
) -> (kind: String?, value: Double?, unit: String?, maxRef: String?) {
    switch load {
    case nil:
        return (nil, nil, nil, nil)
    case .absolute(let weight):
        return ("absolute", weight.value, weight.unit.symbol, nil)
    case .percentOf(let percent, let reference):
        return ("percentOf", percent, nil, reference.rawValue)
    }
}

private func decodeLoad(
    kind: String?,
    value: Double?,
    unit: String?,
    maxRef: String?
) -> LoadPrescription? {
    guard let kind, let value else { return nil }
    switch kind {
    case "absolute":
        return .absolute(measurement(value: value, symbol: unit))
    case "percentOf":
        // A percentage without a legible reference is unresolvable by definition
        // — drop the load rather than guess which max was meant.
        guard let reference = maxRef.flatMap(MaxReference.init(rawValue:)) else { return nil }
        return .percentOf(value, of: reference)
    default:
        // An unknown discriminator means a newer version wrote this row. Dropping
        // the load is better than guessing a weight for it.
        return nil
    }
}

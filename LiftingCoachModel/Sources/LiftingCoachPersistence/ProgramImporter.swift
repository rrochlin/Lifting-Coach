import Foundation
import LiftingCoachModel

/// Imports a training block from the extracted-program JSON format (see
/// `Resources/Block1.json`, extracted from the owner's real spreadsheet).
///
/// **Dev-time tool, not a user feature.** Per Core Tenets §11, the app never
/// parses a spreadsheet and never will — this exists solely to seed the
/// owner's own program as sample data. It is not the start of an in-app
/// "upload your xlsx" capability; a real import feature is either a documented
/// JSON/CSV schema or the phase 2 AI coach interviewing the lifter, never a parser.
///
/// Mapping decisions, per Core Tenets:
/// - The sheet's percentages multiply *goal* maxes — the plan is written against
///   targets, not verified lifts — so `percentOf1RM` maps to
///   `.percentOf(_, of: .goal)`, and the sheet's maxes import as `GoalMax`es.
/// - A JSON set whose load kind is `rpe` has no load: the RPE *is* the whole
///   prescription. It imports as `load: nil` with the effort carried separately.
/// - Exercise-level `targetRPE` becomes `PlannedExercise.effort`; a set-level
///   value is stored only where it differs from the exercise's ("5×2 @ RPE 7"
///   is one instruction, not five).
public struct ProgramImporter {
    public struct Result: Sendable {
        public var block: WorkoutBlock
        public var dayCount: Int
        public var setCount: Int
        public var goalMaxCount: Int
    }

    private let database: AppDatabase
    private let calendar: Calendar

    public init(_ database: AppDatabase, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
    }

    /// The bundled sample block (the owner's real 12-week program).
    public static var bundledBlock1: Data {
        get throws {
            guard let url = Bundle.module.url(forResource: "Block1", withExtension: "json") else {
                throw ImportError.missingResource
            }
            return try Data(contentsOf: url)
        }
    }

    /// Parses and persists a program, scheduling week 1 day 1 on `startDate`.
    ///
    /// The JSON is date-free (week/dayOfWeek only); dates materialize as
    /// `startDate + (week-1)*7 + (dayOfWeek-1)` days, so the program's weekly
    /// shape is preserved wherever the block starts.
    @discardableResult
    public func importProgram(
        _ data: Data,
        for userId: UUID,
        startDate: Date
    ) throws -> Result {
        let file = try JSONDecoder().decode(ProgramFile.self, from: data)
        let start = calendar.startOfDay(for: startDate)

        // Catalog: reuse an existing exercise by exact name, otherwise create
        // above the seed range so imports never collide with built-ins.
        let exercises = ExerciseStore(database)
        var catalog: [String: Exercise] = [:]
        var nextID = max(100, (try exercises.fetchAll().map(\.id).max() ?? 0) + 1)
        for existing in try exercises.fetchAll() {
            catalog[existing.name] = existing
        }
        for entry in file.exerciseCatalog where catalog[entry.name] == nil {
            let exercise = Exercise(id: nextID, name: entry.name, muscleGroup: entry.muscleGroup)
            try exercises.save(exercise)
            catalog[entry.name] = exercise
            nextID += 1
        }

        // The sheet's maxes are explicitly goals (targets, not verified lifts).
        //
        // The sheet resolves percentages by lift, not by exercise identity: a
        // "Bench press — heavy (paused)" row multiplies the *bench* goal. Each
        // program exercise carries a percentReference naming which lift it
        // resolves against, so the goal lands on every exercise that programs
        // off it — the canonical lift and its variations alike.
        // percentReference.lift uses short names ("Bench", "Squat", "Deadlift")
        // while oneRepMaxes uses full ones ("Bench Press", "Back Squat") — key
        // the goal under any word of its name so both resolve.
        var goalByLift: [String: ProgramFile.Max] = [:]
        for goal in file.oneRepMaxes {
            goalByLift[goal.exercise] = goal
            for word in goal.exercise.split(separator: " ") {
                goalByLift[String(word)] = goal
            }
        }

        var referencedBy: [String: Set<Int>] = [:]
        for day in file.days {
            for entry in day.exercises {
                guard let lift = entry.percentReference?.lift,
                      let exercise = catalog[entry.name] else { continue }
                referencedBy[lift, default: []].insert(exercise.id)
            }
        }

        var goalMaxCount = 0
        var assigned = Set<Int>()
        let users = UserStore(database, calendar: calendar)
        for goal in file.oneRepMaxes {
            var targets = Set<Int>()
            for (lift, ids) in referencedBy where goalByLift[lift]?.exercise == goal.exercise {
                targets.formUnion(ids)
            }
            // the canonical lift itself (seed catalog) also gets the goal
            if let canonical = catalog[goal.exercise] ?? bigThreeMatch(goal.exercise, in: catalog) {
                targets.insert(canonical.id)
            }
            for exerciseId in targets where !assigned.contains(exerciseId) {
                assigned.insert(exerciseId)
                try users.setGoalMax(
                    GoalMax(
                        weight: Measurement(value: goal.value, unit: unit(goal.unit)),
                        dateSet: start
                    ),
                    exerciseId: exerciseId,
                    for: userId
                )
                goalMaxCount += 1
            }
        }

        // Program: one PlannedWorkout per JSON day.
        var program: [Date: [PlannedWorkout]] = [:]
        var setCount = 0
        for day in file.days {
            let offset = (day.week - 1) * 7 + (day.dayOfWeek - 1)
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }

            var groups: [[PlannedExercise]] = []
            for entry in day.exercises {
                guard let exercise = catalog[entry.name] else { continue }

                let exerciseEffort = entry.targetRPE.map { EffortTarget(rpe: $0) }
                let sets = entry.sets.map { set -> PlannedSet in
                    setCount += 1
                    return PlannedSet(
                        reps: set.reps,
                        type: set.type.flatMap(SetType.init(rawValue:)),
                        load: importLoad(set.load),
                        // store per-set effort only where it differs from the
                        // exercise's target — the exercise target is the norm
                        effort: set.targetRPE.flatMap { rpe in
                            rpe == entry.targetRPE ? nil : EffortTarget(rpe: rpe)
                        },
                        restTime: set.restTime,
                        notes: set.notes
                    )
                }

                let planned = PlannedExercise(
                    exercise: exercise,
                    sets: sets,
                    effort: exerciseEffort,
                    notes: entry.notes
                )

                // supersetGroup groups exercises performed together; the source
                // program happens not to use it, but honor it if present.
                if entry.supersetGroup < groups.count,
                   entry.orderInGroup > 0 {
                    groups[entry.supersetGroup].append(planned)
                } else {
                    groups.append([planned])
                }
            }

            let workout = PlannedWorkout(
                date: date,
                exercises: groups.isEmpty ? nil : groups,
                notes: day.label
            )
            program[date, default: []].append(workout)
        }

        let end = calendar.date(byAdding: .day, value: file.weeks * 7 - 1, to: start)
        let block = WorkoutBlock(
            program: program,
            startDate: start,
            endDate: end,
            notes: file.blockName
        )

        try PlanStore(database, calendar: calendar).save(block, userId: userId)

        return Result(
            block: block,
            dayCount: file.days.count,
            setCount: setCount,
            goalMaxCount: goalMaxCount
        )
    }

    // MARK: Mapping

    private func importLoad(_ load: ProgramFile.Load?) -> LoadPrescription? {
        guard let load else { return nil }
        switch load.kind {
        case "absolute":
            return .absolute(Measurement(value: load.value, unit: unit(load.unit ?? "lb")))
        case "percentOf1RM":
            // The sheet's percentages reference its goal maxes explicitly.
            return .percentOf(load.value, of: .goal)
        case "rpe":
            // Not a load at all: the RPE is the whole prescription, carried in
            // the effort field. Nothing goes on the bar axis.
            return nil
        default:
            return nil
        }
    }

    /// The sheet names maxes "Back Squat"/"Bench Press"/"Deadlift" while program
    /// rows use variation names — fall back to a seed-catalog match for the big
    /// three so goals land on the canonical lifts.
    private func bigThreeMatch(_ name: String, in catalog: [String: Exercise]) -> Exercise? {
        ExerciseCatalog.seed.first { $0.name == name }
    }

    private func unit(_ symbol: String) -> UnitMass {
        symbol == "kg" ? .kilograms : .pounds
    }

    public enum ImportError: Error {
        case missingResource
    }
}

// MARK: - JSON shape

private struct ProgramFile: Decodable {
    var blockName: String
    var weeks: Int
    var oneRepMaxes: [Max]
    var exerciseCatalog: [CatalogEntry]
    var days: [Day]

    struct Max: Decodable {
        var exercise: String
        var value: Double
        var unit: String
    }

    struct CatalogEntry: Decodable {
        var name: String
        var muscleGroup: String
    }

    struct Day: Decodable {
        var week: Int
        var dayOfWeek: Int
        var label: String
        var exercises: [ExerciseEntry]
    }

    struct ExerciseEntry: Decodable {
        var name: String
        var supersetGroup: Int
        var orderInGroup: Int
        var targetRPE: Float?
        var percentReference: PercentReference?
        var notes: String?
        var sets: [SetEntry]
    }

    struct PercentReference: Decodable {
        var lift: String
    }

    struct SetEntry: Decodable {
        var reps: Int?
        var type: String?
        var load: Load?
        var restTime: Int?
        var notes: String?
        var targetRPE: Float?
    }

    struct Load: Decodable {
        var kind: String
        var value: Double
        var unit: String?
    }
}

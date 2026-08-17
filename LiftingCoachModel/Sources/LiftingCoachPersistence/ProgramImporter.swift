import Foundation
import LiftingCoachModel

/// Imports a training block from the extracted-program JSON format (see
/// `Resources/Block1.json`, extracted from the owner's real spreadsheet).
///
/// **Dev-time tool, not a user feature** (see `Roadmap.md`'s deferred list).
/// This exists solely to seed the owner's own program as sample data — don't
/// extend or generalize it. A real import feature, if it ever happens, is
/// either a documented JSON/CSV schema or the phase 2 AI coach interviewing
/// the lifter, never a parser like this one.
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

    /// The hand-checked program-name → catalog-slug mapping, keyed by program
    /// name. See `ProgramExerciseMap.json`; a one-time artifact, not something
    /// to grow into a general matcher.
    static func bundledExerciseMap() throws -> [String: MapEntry] {
        guard let url = Bundle.module.url(forResource: "ProgramExerciseMap", withExtension: "json") else {
            throw ImportError.missingResource
        }
        let entries = try JSONDecoder().decode([MapEntry].self, from: Data(contentsOf: url))
        return Dictionary(entries.map { ($0.programName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    struct MapEntry: Decodable {
        var programName: String
        /// `nil` for an open-choice slot — it names a goal, not a movement.
        var slug: String?
        var openChoice: Bool
        /// How many exercises the slot expands to. >1 means the program calls
        /// for a superset (e.g. "Triceps + biceps" is two slots).
        var slots: Int
        var muscleGroups: [String]
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

        // Resolve every program exercise onto the vendored catalog rather than
        // minting a sheet-derived entry for it.
        //
        // `ProgramExerciseMap.json` is a hand-checked, one-time mapping from the
        // spreadsheet's names to catalog slugs — "Bench volume — Spoto press"
        // and "Bench — back-off (paused)" are tempo/intensity variants of one
        // movement, not two more entries the catalog should carry. Without this
        // the import polluted the catalog with ~20 near-duplicates that then
        // each accrued their own achieved max.
        //
        // The exception is a slot the program deliberately leaves open ("pick a
        // triceps exercise"): that isn't a movement, so it can't be a catalog
        // entry. Those get a placeholder flagged `isOpenChoice`, which the
        // tracker resolves to a real exercise when the lifter picks one.
        // Keyed by program name; the value is one exercise per *slot*, so a
        // multi-slot entry ("Triceps + biceps") yields two distinct
        // placeholders that can each be filled and tracked independently.
        let exercises = ExerciseStore(database)
        let mapping = try Self.bundledExerciseMap()
        var catalog: [String: [Exercise]] = [:]
        var existing = try exercises.fetchAll()
        var nextID = max(100, (existing.map(\.id).max() ?? 0) + 1)

        for entry in file.exerciseCatalog {
            guard let mapped = mapping[entry.name] else { continue }

            if let slug = mapped.slug, let canonical = try exercises.fetch(sourceSlug: slug) {
                catalog[entry.name] = [canonical]
                continue
            }

            let slotCount = Swift.max(1, mapped.slots)
            var slots: [Exercise] = []
            for slot in 0..<slotCount {
                // A slot's own name: the muscle it targets when the entry
                // splits, otherwise the program's name for it.
                let name = slotCount > 1 && slot < mapped.muscleGroups.count
                    ? mapped.muscleGroups[slot]
                    : entry.name
                let muscle = mapped.muscleGroups.indices.contains(slot)
                    ? mapped.muscleGroups[slot]
                    : (mapped.muscleGroups.first ?? entry.muscleGroup)

                // Reuse by name so a re-import doesn't duplicate placeholders.
                if let found = existing.first(where: { $0.name == name }) {
                    slots.append(found)
                    continue
                }
                let placeholder = Exercise(
                    id: nextID,
                    name: name,
                    muscleGroup: muscle,
                    isOpenChoice: mapped.openChoice
                )
                try exercises.save(placeholder)
                existing.append(placeholder)
                slots.append(placeholder)
                nextID += 1
            }
            catalog[entry.name] = slots
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
                      let slots = catalog[entry.name] else { continue }
                for slot in slots { referencedBy[lift, default: []].insert(slot.id) }
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
            // Every program row that references this lift now resolves to the
            // canonical catalog entry, so `referencedBy` already holds it — no
            // seed-catalog fallback needed (and the seed entries are exactly
            // the duplicates this mapping exists to stop creating).
            if let canonical = catalog[goal.exercise]?.first {
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
                guard let slotExercises = catalog[entry.name], !slotExercises.isEmpty else { continue }

                let exerciseEffort = entry.targetRPE.map { EffortTarget(rpe: $0) }

                // A multi-slot open-choice entry expands into one PlannedExercise
                // per slot inside a single superset group: "Triceps + biceps" is
                // the program calling for two exercises performed together, one
                // per muscle, each filled in by the lifter at workout time. One
                // combined placeholder couldn't express that, and couldn't
                // record which two exercises actually got done.
                //
                // Sets are rebuilt per slot rather than shared: PlannedSet
                // carries an identity, and reusing one array across both slots
                // gives two exercises the same set ids (a UNIQUE violation on
                // insert, and two rows that would edit as one if it got past).
                let planned: [PlannedExercise] = slotExercises.map { slotExercise in
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
                    return PlannedExercise(
                        exercise: slotExercise,
                        sets: sets,
                        effort: exerciseEffort,
                        // Keep the program's own wording where the exercise
                        // resolved onto a canonical catalog entry. Monday
                        // prescribes heavy paused bench *and* its back-off
                        // sets; both are Barbell Bench Press (correctly — they
                        // share a max), and without this the day would read as
                        // the same exercise listed twice.
                        //
                        // Not set for a placeholder, whose name already is the
                        // program's own ("Triceps (overhead ext / pushdown)")
                        // or the muscle a split slot targets.
                        variant: slotExercise.sourceSlug == nil ? nil : entry.name,
                        notes: entry.notes
                    )
                }

                if slotExercises.count > 1 {
                    // The slots ARE the superset — they always travel together.
                    groups.append(planned)
                    continue
                }

                // supersetGroup groups exercises performed together; the source
                // program happens not to use it, but honor it if present.
                if entry.supersetGroup < groups.count,
                   entry.orderInGroup > 0 {
                    groups[entry.supersetGroup].append(contentsOf: planned)
                } else {
                    groups.append(planned)
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

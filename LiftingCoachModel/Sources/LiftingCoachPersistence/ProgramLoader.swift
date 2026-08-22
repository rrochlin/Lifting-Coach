import Foundation
import LiftingCoachModel

/// Loads a training block written in the app's own language (see
/// `Resources/Block1.json`) into the database.
///
/// **This is a loader, not a translator.** The file it reads already says
/// exactly what the app means: an exercise is named by its catalog slug, or it
/// is an open slot the lifter fills, and the file says which. Nothing here
/// inspects a name, guesses at a movement, or decides what a prescription
/// probably meant — a program that can't be loaded is a program that was
/// written wrong, and it fails rather than approximating.
///
/// That's the whole reason the bundled block is a hand-checked translation of
/// the owner's spreadsheet rather than something parsed at runtime. The
/// judgment ("is 'Incline press (BB or DB)' one lift or the lifter's choice?")
/// happened once, by a person, and is recorded in the file. See
/// `Concepts.md`'s "Programs name exercises, they don't describe them."
///
/// Mapping decisions, per Core Tenets:
/// - `percentOfGoal` loads become `.percentOf(_, of: .goal)` — the block is
///   written against targets, not verified lifts, so the file's maxes import as
///   `GoalMax`es.
/// - A set with no `load` has no load: the RPE *is* the whole prescription.
/// - An exercise's `rpe` becomes `PlannedExercise.effort`; a set carries one
///   only where it differs ("5×2 @ RPE 7" is one instruction, not five).
public struct ProgramLoader {
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
                throw LoadError.missingResource
            }
            return try Data(contentsOf: url)
        }
    }

    /// Loads and persists a program, scheduling week 1 day 1 on `startDate`.
    ///
    /// The file is date-free (week/dayOfWeek only); dates materialize as
    /// `startDate + (week-1)*7 + (dayOfWeek-1)` days, so the program's weekly
    /// shape is preserved wherever the block starts.
    @discardableResult
    public func load(
        _ data: Data,
        for userId: UUID,
        startDate: Date
    ) throws -> Result {
        let file = try JSONDecoder().decode(ProgramFile.self, from: data)
        let start = calendar.startOfDay(for: startDate)
        let exercises = ExerciseStore(database)

        let openSlots = try resolveOpenSlots(file.openChoiceExercises, in: exercises)
        let goalMaxCount = try applyGoalMaxes(file.goalMaxes, for: userId, at: start, in: exercises)

        var program: [Date: [PlannedWorkout]] = [:]
        var setCount = 0

        for day in file.days {
            let offset = (day.week - 1) * 7 + (day.dayOfWeek - 1)
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }

            var groups: [[PlannedExercise]] = []
            for group in day.exercises {
                // A group is a superset: everything in it is performed
                // together. Most groups hold one exercise; a program row that
                // calls for two ("triceps + biceps") is two, so the lifter can
                // pick and log a movement for each independently.
                var planned: [PlannedExercise] = []
                for entry in group {
                    let exercise = try resolve(entry, openSlots: openSlots, in: exercises)
                    let sets = entry.sets.map { set -> PlannedSet in
                        // Sets prescribed, not rows written — a `count: 4` row
                        // is four sets, and the count this reports is checked
                        // against the source spreadsheet.
                        setCount += set.count ?? 1
                        return PlannedSet(
                            count: set.count ?? 1,
                            reps: set.reps,
                            type: set.type.flatMap(SetType.init(rawValue:)),
                            load: load(set.load),
                            effort: set.rpe.map { EffortTarget(rpe: $0) },
                            restTime: set.restTime,
                            notes: set.notes
                        )
                    }
                    planned.append(
                        PlannedExercise(
                            exercise: exercise,
                            sets: sets,
                            effort: entry.rpe.map { EffortTarget(rpe: $0) },
                            // The program's own wording for this slot. Monday
                            // prescribes heavy paused bench *and* its back-off
                            // sets; both are the same catalog entry (correctly
                            // — they share a max), and without this the day
                            // would read as one exercise listed twice.
                            variant: entry.variant,
                            notes: entry.notes
                        )
                    )
                }
                groups.append(planned)
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
            notes: file.name
        )

        try PlanStore(database, calendar: calendar).save(block, userId: userId)

        return Result(
            block: block,
            dayCount: file.days.count,
            setCount: setCount,
            goalMaxCount: goalMaxCount
        )
    }

    // MARK: Resolving exercises

    /// Finds or creates the catalog row for each open slot the program declares.
    ///
    /// These are the only exercises this loader ever creates. An open slot
    /// isn't a movement, so no canonical catalog entry can stand for it —
    /// "pick a triceps exercise" is a real, deliberate prescription with no
    /// single lift behind it. Reused by name so re-loading doesn't mint a
    /// second copy of one.
    private func resolveOpenSlots(
        _ declared: [ProgramFile.OpenChoiceExercise],
        in store: ExerciseStore
    ) throws -> [String: Exercise] {
        var existing = try store.fetchAll()
        var nextID = max(100, (existing.map(\.id).max() ?? 0) + 1)
        var resolved: [String: Exercise] = [:]

        for slot in declared {
            if let found = existing.first(where: { $0.name == slot.name && $0.isOpenChoice }) {
                resolved[slot.key] = found
                continue
            }
            let exercise = Exercise(
                id: nextID,
                name: slot.name,
                muscleGroup: slot.muscleGroup,
                isOpenChoice: true,
                suggestions: slot.suggestions.isEmpty ? nil : slot.suggestions
            )
            try store.save(exercise)
            existing.append(exercise)
            resolved[slot.key] = exercise
            nextID += 1
        }
        return resolved
    }

    private func resolve(
        _ entry: ProgramFile.Exercise,
        openSlots: [String: Exercise],
        in store: ExerciseStore
    ) throws -> Exercise {
        if let key = entry.openChoice {
            guard let slot = openSlots[key] else { throw LoadError.unknownOpenChoice(key) }
            return slot
        }
        guard let slug = entry.exercise else { throw LoadError.exerciseNotNamed }
        // No fallback and no fuzzy lookup: a slug that isn't in the catalog is a
        // mistake in the program file, and silently dropping the exercise would
        // hide a missing day's work behind a plan that looks complete.
        guard let exercise = try store.fetch(sourceSlug: slug) else {
            throw LoadError.unknownExercise(slug)
        }
        return exercise
    }

    // MARK: Goal maxes

    /// The file's maxes are explicitly goals — targets to program against, not
    /// verified lifts (Core Tenets §6).
    ///
    /// Each entry lists every exercise it applies to, because a sheet's
    /// "deadlift max" governs the percentages of the deficit and paused
    /// variations too. That used to be inferred from which rows referenced
    /// which lift; the file states it now, so there's nothing to work out.
    private func applyGoalMaxes(
        _ maxes: [ProgramFile.GoalMaxEntry],
        for userId: UUID,
        at date: Date,
        in store: ExerciseStore
    ) throws -> Int {
        let users = UserStore(database, calendar: calendar)
        var count = 0
        for entry in maxes {
            for slug in entry.exercises {
                guard let exercise = try store.fetch(sourceSlug: slug) else {
                    throw LoadError.unknownExercise(slug)
                }
                try users.setGoalMax(
                    GoalMax(
                        weight: Measurement(value: entry.weight, unit: unit(entry.unit)),
                        dateSet: date
                    ),
                    exerciseId: exercise.id,
                    for: userId
                )
                count += 1
            }
        }
        return count
    }

    // MARK: Mapping

    private func load(_ load: ProgramFile.Load?) -> LoadPrescription? {
        guard let load else { return nil }
        switch load.kind {
        case "absolute":
            return .absolute(Measurement(value: load.value, unit: unit(load.unit ?? "lb")))
        case "percentOfGoal":
            return .percentOf(load.value, of: .goal)
        default:
            return nil
        }
    }

    private func unit(_ symbol: String) -> UnitMass {
        symbol == "kg" ? .kilograms : .pounds
    }

    public enum LoadError: Error, Equatable {
        case missingResource
        /// The program names a catalog slug that isn't in the catalog.
        case unknownExercise(String)
        /// The program references an open slot it never declared.
        case unknownOpenChoice(String)
        /// An entry names neither an exercise nor an open slot.
        case exerciseNotNamed
    }
}

// MARK: - File shape

/// The on-disk program format. Mirrors the domain types closely enough that
/// this decodes almost straight across — which is the point: the file is
/// written in the app's language, so loading it is transcription, not
/// interpretation.
private struct ProgramFile: Decodable {
    var name: String
    var weeks: Int
    var goalMaxes: [GoalMaxEntry]
    var openChoiceExercises: [OpenChoiceExercise]
    var days: [Day]

    struct GoalMaxEntry: Decodable {
        var weight: Double
        var unit: String
        /// Every catalog slug this max is the goal for.
        var exercises: [String]
        /// Free text explaining a non-obvious grouping. Documentation for
        /// whoever reads the file; nothing reads it.
        var note: String?
    }

    struct OpenChoiceExercise: Decodable {
        /// How days refer to this slot.
        var key: String
        var name: String
        var muscleGroup: String
        var suggestions: [String]
    }

    struct Day: Decodable {
        var week: Int
        var dayOfWeek: Int
        var label: String
        /// Groups of exercises; each inner array is one superset.
        var exercises: [[Exercise]]
    }

    struct Exercise: Decodable {
        /// A catalog slug. Mutually exclusive with `openChoice`.
        var exercise: String?
        /// An open slot's key. Mutually exclusive with `exercise`.
        var openChoice: String?
        /// The program's own wording for this slot.
        var variant: String?
        var rpe: Float?
        var notes: String?
        var sets: [Set]
    }

    struct Set: Decodable {
        /// How many identical sets this row prescribes. Absent means one, so a
        /// program written a row at a time still loads unchanged.
        var count: Int?
        var reps: Int?
        var type: String?
        var load: Load?
        /// Present only where this set's effort differs from the exercise's.
        var rpe: Float?
        var restTime: Int?
        var notes: String?
    }

    struct Load: Decodable {
        var kind: String
        var value: Double
        var unit: String?
    }
}

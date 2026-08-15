import Foundation
import Observation
import LiftingCoachModel
import LiftingCoachPersistence

/// View state for the Workout Planner.
///
/// Shows one block at a time, per `Workout Planner.md`. The block on screen
/// defaults to the current one — derived from `startDate`, so a block that has
/// run past its planned end stays selected instead of vanishing on a slipped
/// schedule.
@Observable
@MainActor
final class PlannerModel {
    private(set) var plan = WorkoutPlan()
    private(set) var selectedBlockID: UUID?
    private(set) var loadError: String?

    private let plans: PlanStore
    private let userID: UUID
    private let calendar: Calendar

    init(plans: PlanStore, userID: UUID, calendar: Calendar = .current) {
        self.plans = plans
        self.userID = userID
        self.calendar = calendar
    }

    // MARK: Reading

    var blocks: [WorkoutBlock] { plan.scheduledBlocks }

    var selectedBlock: WorkoutBlock? {
        guard let selectedBlockID else { return nil }
        return plan.blocks?.first { $0.id == selectedBlockID }
    }

    /// Days in the selected block that have anything programmed, in order.
    var programmedDays: [Date] {
        (selectedBlock?.program ?? [:]).keys.sorted()
    }

    func plannedWorkouts(on day: Date) -> [PlannedWorkout] {
        selectedBlock?.program?[day] ?? []
    }

    /// What's programmed for today, across every block — what the tracker and
    /// homepage start from.
    func todaysWorkouts(asOf date: Date = Date()) -> [PlannedWorkout] {
        (try? plans.fetchPlanned(on: date)) ?? []
    }

    // MARK: Loading

    func load(asOf date: Date = Date()) {
        do {
            plan = try plans.fetchPlan(userId: userID)
            if selectedBlockID == nil || selectedBlock == nil {
                selectedBlockID = plan.currentBlock(asOf: date, calendar: calendar)?.id
                    ?? plan.scheduledBlocks.last?.id
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func select(blockID: UUID) {
        selectedBlockID = blockID
    }

    // MARK: Editing

    /// Creates a block and selects it.
    @discardableResult
    func createBlock(
        startDate: Date,
        weeks: Int,
        notes: String?
    ) -> WorkoutBlock? {
        let end = calendar.date(byAdding: .day, value: weeks * 7 - 1, to: startDate)
        let block = WorkoutBlock(
            startDate: calendar.startOfDay(for: startDate),
            endDate: end.map { calendar.startOfDay(for: $0) },
            notes: notes,
            // Sensible starting points; per-set prescriptions override these, and
            // most sets shouldn't need to.
            defaultRestTimes: [.warmup: 60, .working: 180, .drop: 60]
        )

        guard persist({ try plans.save(block, userId: userID) }) else { return nil }
        load()
        selectedBlockID = block.id
        return block
    }

    func deleteBlock(id: UUID) {
        guard persist({ try plans.deleteBlock(id: id) }) else { return }
        if selectedBlockID == id { selectedBlockID = nil }
        load()
    }

    /// Adds an empty workout on a day of the selected block.
    @discardableResult
    func addPlannedWorkout(on day: Date) -> PlannedWorkout? {
        guard let blockID = selectedBlockID else { return nil }
        let workout = PlannedWorkout(date: calendar.startOfDay(for: day))

        guard persist({ try plans.save(workout, in: blockID) }) else { return nil }
        load()
        return workout
    }

    func save(_ workout: PlannedWorkout) {
        guard let blockID = selectedBlockID else { return }
        guard persist({ try plans.save(workout, in: blockID) }) else { return }
        load()
    }

    func deletePlannedWorkout(id: UUID) {
        guard persist({ try plans.deletePlannedWorkout(id: id) }) else { return }
        load()
    }

    /// Appends an exercise to a planned workout as its own group.
    func addExercise(_ exercise: Exercise, to workout: PlannedWorkout, sets: Int = 3) {
        var workout = workout
        let planned = PlannedExercise(
            exercise: exercise,
            sets: (0..<sets).map { _ in PlannedSet(reps: 5, type: .working) }
        )
        workout.exercises = (workout.exercises ?? []) + [[planned]]
        save(workout)
    }

    func deleteExercise(id: UUID, from workout: PlannedWorkout) {
        var workout = workout
        var groups = workout.exercises ?? []
        for index in groups.indices {
            groups[index].removeAll { $0.id == id }
        }
        // A group emptied by the deletion would otherwise render as a blank row.
        groups.removeAll(where: \.isEmpty)
        workout.exercises = groups
        save(workout)
    }

    /// Applies an edit to one set inside a planned workout.
    func updateSet(id: UUID, in workout: PlannedWorkout, _ change: (inout PlannedSet) -> Void) {
        var workout = workout
        var groups = workout.exercises ?? []
        for groupIndex in groups.indices {
            for exerciseIndex in groups[groupIndex].indices {
                guard var sets = groups[groupIndex][exerciseIndex].sets,
                      let setIndex = sets.firstIndex(where: { $0.id == id })
                else { continue }
                change(&sets[setIndex])
                groups[groupIndex][exerciseIndex].sets = sets
            }
        }
        workout.exercises = groups
        save(workout)
    }

    func addSet(to exerciseID: UUID, in workout: PlannedWorkout) {
        var workout = workout
        var groups = workout.exercises ?? []
        for groupIndex in groups.indices {
            for exerciseIndex in groups[groupIndex].indices
            where groups[groupIndex][exerciseIndex].id == exerciseID {
                let sets = groups[groupIndex][exerciseIndex].sets ?? []
                // Copy the last set's shape — programming is repetitive by nature.
                let template = sets.last
                groups[groupIndex][exerciseIndex].sets = sets + [
                    PlannedSet(
                        reps: template?.reps ?? 5,
                        type: template?.type ?? .working,
                        load: template?.load,
                        restTime: template?.restTime
                    )
                ]
            }
        }
        workout.exercises = groups
        save(workout)
    }

    func deleteSet(id: UUID, in workout: PlannedWorkout) {
        var workout = workout
        var groups = workout.exercises ?? []
        for groupIndex in groups.indices {
            for exerciseIndex in groups[groupIndex].indices {
                groups[groupIndex][exerciseIndex].sets?.removeAll { $0.id == id }
            }
        }
        workout.exercises = groups
        save(workout)
    }

    // MARK: Plumbing

    /// Runs a write, surfacing failure rather than swallowing it. Returns whether
    /// it succeeded, so callers don't reload from a store that just failed.
    private func persist(_ write: () throws -> Void) -> Bool {
        do {
            try write()
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }
}

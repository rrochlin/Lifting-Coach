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
///
/// Structural edits (create a block, add or remove a day) write immediately —
/// there's nothing to review about them. Editing what a day *prescribes* goes
/// through `PlannedWorkoutDraft` and lands only on an explicit save; see
/// `saveDraft`.
@Observable
@MainActor
final class PlannerModel {
    private(set) var plan = WorkoutPlan()
    private(set) var selectedBlockID: UUID?
    private(set) var loadError: String?

    /// The lifter, so `%1RM` prescriptions can be shown as real weights while
    /// authoring rather than as bare percentages. Optional throughout: an
    /// unresolvable percentage displays as written (Core Tenets §10).
    var user: User?

    private let plans: PlanStore
    private let userID: UUID
    let calendar: Calendar

    init(plans: PlanStore, userID: UUID, user: User? = nil, calendar: Calendar = .current) {
        self.plans = plans
        self.userID = userID
        self.user = user
        self.calendar = calendar
    }

    // MARK: Reading

    var blocks: [WorkoutBlock] { plan.scheduledBlocks }

    var selectedBlock: WorkoutBlock? {
        guard let selectedBlockID else { return nil }
        return plan.blocks?.first { $0.id == selectedBlockID }
    }

    /// The selected block's programmed days grouped into its training weeks —
    /// the planner's navigation unit. A 12-week program is ~70 days, and a flat
    /// list of them is exactly the "can't tell what's going on" problem.
    var programmedWeeks: [WorkoutBlock.ProgrammedWeek] {
        selectedBlock?.programmedWeeks(calendar: calendar) ?? []
    }

    /// The week the lifter is actually in, for defaulting what's expanded.
    /// `nil` before the block starts or when it has no start date.
    func currentWeekIndex(asOf date: Date = Date()) -> Int? {
        guard let progress = selectedBlock?.progress(asOf: date, calendar: calendar),
              progress.weekIndex >= 1
        else { return nil }
        return progress.weekIndex
    }

    /// Days in the selected block that have anything programmed, in order.
    var programmedDays: [Date] {
        (selectedBlock?.program ?? [:]).keys.sorted()
    }

    func plannedWorkouts(on day: Date) -> [PlannedWorkout] {
        selectedBlock?.program?[calendar.startOfDay(for: day)] ?? []
    }

    func plannedWorkout(id: UUID) -> PlannedWorkout? {
        (selectedBlock?.program ?? [:]).values.flatMap { $0 }.first { $0.id == id }
    }

    /// What's programmed for today, across every block — what the tracker and
    /// homepage start from.
    func todaysWorkouts(asOf date: Date = Date()) -> [PlannedWorkout] {
        (try? plans.fetchPlanned(on: date)) ?? []
    }

    /// A prescription as a real weight, where the referenced max is recorded.
    /// `nil` is a legitimate answer — the caller shows the prescription as
    /// written instead of inventing a number.
    func resolvedWeight(for load: LoadPrescription, exercise: Exercise) -> Measurement<UnitMass>? {
        // Absolute loads don't need the lifter at all, so resolve through the
        // prescription rather than gating everything behind an optional User.
        load.resolvedWeight { reference in user?.max(reference, for: exercise.id) }
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

    // MARK: Structural editing

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

    func deletePlannedWorkout(id: UUID) {
        guard persist({ try plans.deletePlannedWorkout(id: id) }) else { return }
        load()
    }

    // MARK: Draft editing

    /// Writes an edited day, then rebases the draft onto what was written.
    ///
    /// Order matters: `markSaved()` only runs once the store write has actually
    /// succeeded, so a failed save leaves the draft dirty and the lifter's work
    /// on screen rather than reporting it as saved and losing it.
    @discardableResult
    func saveDraft(_ draft: inout PlannedWorkoutDraft) -> Bool {
        guard let blockID = selectedBlockID else { return false }
        guard persist({ try plans.save(draft.workout, in: blockID) }) else { return false }
        draft.markSaved()
        load()
        return true
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

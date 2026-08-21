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

    /// Which of the selected block's programmed days have actually been
    /// trained. Empty until `load()` runs, and empty for a block with nothing
    /// programmed — there is nothing to have completed.
    private(set) var completion = BlockCompletion()

    private let plans: PlanStore
    private let workouts: WorkoutStore
    private let userID: UUID
    let calendar: Calendar

    init(
        plans: PlanStore,
        workouts: WorkoutStore,
        userID: UUID,
        user: User? = nil,
        calendar: Calendar = .current
    ) {
        self.plans = plans
        self.workouts = workouts
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
    ///
    /// Comes back in the lifter's own unit, because every caller is displaying
    /// it. Note the split this creates in the planner and it is the intended
    /// one: an *authored* absolute load keeps the unit it was written in (the
    /// load mode menu is where that's chosen), while a weight the app *derives*
    /// — 72% of a 495 lb goal — reads in whatever the lifter asked to read in.
    func resolvedWeight(for load: LoadPrescription, exercise: Exercise) -> Measurement<UnitMass>? {
        // Absolute loads don't need the lifter at all, so resolve through the
        // prescription rather than gating everything behind an optional User.
        let weight = load.resolvedWeight { reference in user?.max(reference, for: exercise.id) }
        return weight?.expressed(in: user?.preferredUnit ?? .pounds)
    }

    /// Rest a planned set resolves to: its own value, then the selected block's
    /// default for its type, then the app default. The same chain
    /// `WorkoutSession` walks at lift time, so what the planner shows is what
    /// the tracker will count.
    func restTime(for set: PlannedSet) -> Int {
        selectedBlock?.restTime(for: set) ?? set.restTime ?? 120
    }

    // MARK: Loading

    func load(asOf date: Date = Date()) {
        do {
            plan = try plans.fetchPlan(userId: userID)
            if selectedBlockID == nil || selectedBlock == nil {
                selectedBlockID = plan.currentBlock(asOf: date, calendar: calendar)?.id
                    ?? plan.scheduledBlocks.last?.id
            }
            completion = try loadCompletion()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func select(blockID: UUID) {
        selectedBlockID = blockID
        // The completion is per block, so it has to move when the selection
        // does — otherwise the block you switched to wears the last one's
        // trained days.
        do {
            completion = try loadCompletion()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// What was logged across the span the selected block programs.
    ///
    /// **Summaries, not workouts.** `PlanStore.attachingLoggedWorkouts` is the
    /// other way to answer this and it fully hydrates every set of every
    /// session in the block — thousands of queries to draw a screen that only
    /// needs a date and a count. This is the same three bounded queries the
    /// History calendar uses.
    ///
    /// Scoped to the programmed days rather than to `startDate...endDate`: a
    /// block routinely runs past its planned end (that's why `endDate` is a
    /// target, not a boundary), and days programmed past it still need their
    /// marker.
    ///
    /// **Finished workouts only** — `fetchSummaries` filters on `endTime`.
    /// A session still being logged belongs to the tracker, and counting it
    /// here would tick today's day off while the lifter is stood over the bar
    /// halfway through it. Home's adherence readout does include the live
    /// session, which is right for a running set total and wrong for a
    /// day-done marker.
    private func loadCompletion() throws -> BlockCompletion {
        let days = programmedDays
        guard let first = days.first, let last = days.last else {
            return BlockCompletion(calendar: calendar)
        }
        let summaries = try workouts.fetchSummaries(from: first, to: last)
        return BlockCompletion(
            sessions: summaries.compactMap { summary in
                // A finished workout always has a start; one without a date
                // can't be placed on a day, and inventing one would put it on
                // an arbitrary square.
                summary.startTime.map {
                    BlockCompletion.Session(
                        id: summary.id,
                        startedAt: $0,
                        setCount: summary.completedSetCount
                    )
                }
            },
            calendar: calendar
        )
    }

    /// Completed sets logged on a programmed day, against what it prescribes.
    ///
    /// Both halves on screen is the point: the join is by date (see
    /// `BlockCompletion`), so the app states what was logged that day and lets
    /// the lifter read whether it was the programmed session.
    func dayLog(on day: Date) -> DayLog? {
        guard completion.wasTrained(on: day) else { return nil }
        return DayLog(
            sessions: completion.sessions(on: day).count,
            loggedSets: completion.setCount(on: day),
            plannedSets: plannedWorkouts(on: day).reduce(0) { $0 + $1.allSets.count }
        )
    }

    /// How many of a week's programmed days were trained.
    func trainedDays(in week: WorkoutBlock.ProgrammedWeek) -> Int {
        completion.trainedDays(among: week.days)
    }

    /// The block-level rollup: trained days over programmed days.
    ///
    /// Counted over `programmedWeeks` rather than `programmedDays` so the
    /// header and the week rows are summing the same set of days — the two
    /// differ on a day whose workouts were all deleted, and a header that
    /// doesn't add up to its own rows reads as a bug in both.
    var blockTrainedDays: (trained: Int, programmed: Int) {
        let days = programmedWeeks.flatMap(\.days)
        return (completion.trainedDays(among: days), days.count)
    }

    /// What a programmed day has logged against it.
    struct DayLog: Hashable {
        var sessions: Int
        var loggedSets: Int
        var plannedSets: Int
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

    /// Writes a block's settings — name, dates, length, rest defaults — and the
    /// dates of its programmed days, leaving every prescription alone.
    ///
    /// The shift itself is already in `block` by the time this runs: the editor
    /// builds the moved block with `WorkoutBlock.rescheduled(to:)` and hands it
    /// over whole, so there is one place that knows how a program moves and it
    /// is a tested pure function rather than view code.
    @discardableResult
    func updateBlockSettings(_ block: WorkoutBlock) -> Bool {
        guard persist({ try plans.updateSettings(block, userId: userID) }) else { return false }
        load()
        return true
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

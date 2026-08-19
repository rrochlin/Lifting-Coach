import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

private let squat = ExerciseCatalog.seed[0]
private let bench = ExerciseCatalog.seed[1]
private let row = ExerciseCatalog.seed[4]

private struct Fixture {
    let database: AppDatabase
    let plans: PlanStore
    let workouts: WorkoutStore
    let users: UserStore
    let user: User
}

private func makeFixture() throws -> Fixture {
    let database = try AppDatabase.inMemory()
    try ExerciseStore(database).save(ExerciseCatalog.seed)
    let users = UserStore(database, calendar: calendar)
    return Fixture(
        database: database,
        plans: PlanStore(database, calendar: calendar),
        workouts: WorkoutStore(database, calendar: calendar),
        users: users,
        user: try users.localUser()
    )
}

@Suite("User persistence")
struct UserStoreTests {

    @Test("The local user is created once and reused")
    func createsLocalUserOnce() throws {
        let fixture = try makeFixture()
        let again = try fixture.users.localUser()

        #expect(again.id == fixture.user.id)
    }

    @Test("Maxes and bodyweight round-trip")
    func roundTripsMetrics() throws {
        let fixture = try makeFixture()

        try fixture.users.recordAchievedMax(
            AchievedMax(weight: Measurement(value: 315, unit: .pounds), date: day(2026, 2, 1)),
            exerciseId: squat.id, for: fixture.user.id)
        try fixture.users.setGoalMax(
            GoalMax(weight: Measurement(value: 495, unit: .pounds), dateSet: day(2026, 1, 1)),
            exerciseId: squat.id, for: fixture.user.id)
        try fixture.users.recordBodyWeight(Measurement(value: 198, unit: .pounds), for: fixture.user.id, on: day(2026, 3, 1))

        let loaded = try fixture.users.fetch(id: fixture.user.id)
        #expect(loaded?.max(.achieved, for: squat.id)?.value == 315)
        #expect(loaded?.max(.goal, for: squat.id)?.value == 495)
        #expect(loaded?.currentBodyWeight?.value == 198)
    }

    @Test("Achieved maxes append as history; goal maxes replace")
    func achievedAppendsGoalReplaces() throws {
        let fixture = try makeFixture()

        // Achieved is an event — both lifts are kept, newest resolves.
        try fixture.users.recordAchievedMax(
            AchievedMax(weight: Measurement(value: 315, unit: .pounds), date: day(2026, 1, 1)),
            exerciseId: squat.id, for: fixture.user.id)
        try fixture.users.recordAchievedMax(
            AchievedMax(weight: Measurement(value: 325, unit: .pounds), date: day(2026, 6, 1)),
            exerciseId: squat.id, for: fixture.user.id)

        // Goal is a setting — the second replaces the first.
        try fixture.users.setGoalMax(
            GoalMax(weight: Measurement(value: 475, unit: .pounds)),
            exerciseId: squat.id, for: fixture.user.id)
        try fixture.users.setGoalMax(
            GoalMax(weight: Measurement(value: 495, unit: .pounds)),
            exerciseId: squat.id, for: fixture.user.id)

        let loaded = try fixture.users.fetch(id: fixture.user.id)
        #expect(loaded?.achievedMaxes?[squat.id]?.count == 2)
        #expect(loaded?.max(.achieved, for: squat.id)?.value == 325)
        #expect(loaded?.goalMaxes?.count == 1)
        #expect(loaded?.max(.goal, for: squat.id)?.value == 495)
    }
}

@Suite("Plan persistence")
struct PlanStoreTests {

    private func block(id: UUID = UUID()) -> WorkoutBlock {
        WorkoutBlock(
            id: id,
            program: [
                day(2026, 3, 2): [
                    PlannedWorkout(
                        date: day(2026, 3, 2),
                        exercises: [[
                            PlannedExercise(
                                exercise: squat,
                                sets: [
                                    PlannedSet(reps: 5, type: .warmup, load: .percentOf(0.5, of: .goal)),
                                    PlannedSet(reps: 3, type: .working, load: .percentOf(0.85, of: .goal), effort: EffortTarget(rpe: 9), restTime: 240),
                                ],
                                effort: EffortTarget(rpe: 7)
                            )
                        ]],
                        notes: "Heavy squat day"
                    )
                ],
                day(2026, 3, 4): [
                    PlannedWorkout(
                        date: day(2026, 3, 4),
                        exercises: [[
                            PlannedExercise(
                                exercise: bench,
                                sets: [PlannedSet(reps: 8, type: .working)],
                                effort: EffortTarget(rpe: 8)
                            ),
                            PlannedExercise(exercise: row, sets: [
                                PlannedSet(reps: 8, type: .working, load: .absolute(Measurement(value: 135, unit: .pounds))),
                            ]),
                        ]]
                    )
                ],
            ],
            startDate: day(2026, 3, 1),
            endDate: day(2026, 4, 11),
            notes: "Six-week strength block",
            journal: "Week 1 felt good",
            defaultRestTimes: [.working: 180, .warmup: 60]
        )
    }

    @Test("A block round-trips with its program")
    func roundTripsBlock() throws {
        let fixture = try makeFixture()
        let original = block()

        try fixture.plans.save(original, userId: fixture.user.id)
        let loaded = try fixture.plans.fetchBlock(id: original.id)

        #expect(loaded?.startDate == day(2026, 3, 1))
        #expect(loaded?.endDate == day(2026, 4, 11))
        #expect(loaded?.notes == "Six-week strength block")
        #expect(loaded?.journal == "Week 1 felt good")
        #expect(loaded?.defaultRestTimes?[.working] == 180)
        #expect(loaded?.defaultRestTimes?[.warmup] == 60)
        #expect(loaded?.program?.count == 2)
    }

    @Test("Block settings update without rewriting the program")
    func updatesBlockSettings() throws {
        let fixture = try makeFixture()
        let original = block()
        try fixture.plans.save(original, userId: fixture.user.id)

        var edited = original.rescheduled(to: day(2026, 2, 1), calendar: calendar)
        edited = edited.withLength(weeks: 8, calendar: calendar)
        edited.notes = "Moved back a month"
        edited.defaultRestTimes = [.working: 240]

        try fixture.plans.updateSettings(edited, userId: fixture.user.id)
        let loaded = try fixture.plans.fetchBlock(id: original.id)

        #expect(loaded?.startDate == day(2026, 2, 1))
        #expect(loaded?.endDate == day(2026, 3, 28))
        #expect(loaded?.notes == "Moved back a month")
        #expect(loaded?.defaultRestTimes?[.working] == 240)
        // Cleared, not merged — a rest default the lifter removed has to go.
        #expect(loaded?.defaultRestTimes?[.warmup] == nil)
    }

    /// The safety property `updateSettings` exists for: a start date can move a
    /// 12-week block without any prescription passing through a delete.
    @Test("Moving a block carries its days and keeps every prescription")
    func moveKeepsPrescriptions() throws {
        let fixture = try makeFixture()
        let original = block()
        try fixture.plans.save(original, userId: fixture.user.id)

        let moved = original.rescheduled(to: day(2026, 2, 1), calendar: calendar)
        try fixture.plans.updateSettings(moved, userId: fixture.user.id)
        let loaded = try fixture.plans.fetchBlock(id: original.id)

        // The squat day was Mar 2, one day into a Mar 1 block; it's Feb 2 now.
        #expect(loaded?.program?[day(2026, 3, 2)] == nil)
        let squatDay = loaded?.program?[day(2026, 2, 2)]?.first
        #expect(squatDay?.date == day(2026, 2, 2))

        let squatSets = squatDay?.exercises?[0][0].sets ?? []
        #expect(squatSets.count == 2)
        #expect(squatSets[0].load == .percentOf(0.5, of: .goal))
        #expect(squatSets[1].load == .percentOf(0.85, of: .goal))
        // Identity is untouched too, so nothing downstream sees the move as a
        // delete followed by a fresh day.
        #expect(squatDay?.id == original.program?[day(2026, 3, 2)]?.first?.id)
    }

    @Test("Every load and effort combination survives storage")
    func roundTripsEachLoadKind() throws {
        let fixture = try makeFixture()
        let original = block()
        try fixture.plans.save(original, userId: fixture.user.id)

        let loaded = try fixture.plans.fetchBlock(id: original.id)

        let squatDay = loaded?.program?[day(2026, 3, 2)]?.first
        let squatExercise = squatDay?.exercises?[0][0]
        let squatSets = squatExercise?.sets ?? []
        #expect(squatSets.count == 2)
        #expect(squatSets[0].load == .percentOf(0.5, of: .goal))
        #expect(squatSets[1].load == .percentOf(0.85, of: .goal))
        #expect(squatSets[1].restTime == 240)
        #expect(squatSets[1].type == .working)
        // exercise-level target survives; only the override is stored per set
        #expect(squatExercise?.effort == EffortTarget(rpe: 7))
        #expect(squatSets[0].effort == nil)
        #expect(squatSets[1].effort == EffortTarget(rpe: 9))
        #expect(squatExercise.map { $0.resolvedEffort(for: squatSets[0]) } == EffortTarget(rpe: 7))

        let benchDay = loaded?.program?[day(2026, 3, 4)]?.first
        let benchExercise = benchDay?.exercises?[0][0]
        let rowSets = benchDay?.exercises?[0][1].sets ?? []
        // effort-only prescription: no load axis at all
        #expect(benchExercise?.sets?.first?.load == nil)
        #expect(benchExercise?.effort == EffortTarget(rpe: 8))
        #expect(rowSets.first?.load == .absolute(Measurement(value: 135, unit: .pounds)))
    }

    @Test("A variant round-trips without becoming a second exercise")
    func roundTripsVariant() throws {
        let fixture = try makeFixture()
        var original = block()
        let target = try #require(original.program?[day(2026, 3, 2)]?.first?.id)

        // Two prescriptions of the same catalog lift on one day — the shape
        // the real program produces once it resolves onto the catalog.
        var workout = try #require(original.program?[day(2026, 3, 2)]?.first)
        var first = try #require(workout.exercises?[0][0])
        var second = first
        first.variant = "heavy (paused, comp grip)"
        second.id = UUID()
        second.variant = "back-off (paused)"
        second.sets = (second.sets ?? []).map { set in
            var set = set
            set.id = UUID()
            return set
        }
        workout.exercises = [[first], [second]]
        original.program?[day(2026, 3, 2)] = [workout]

        try fixture.plans.save(original, userId: fixture.user.id)
        let loaded = try fixture.plans.fetchBlock(id: original.id)
        let reloaded = try #require(loaded?.program?[day(2026, 3, 2)]?.first { $0.id == target })
        let exercises = (reloaded.exercises ?? []).flatMap { $0 }

        #expect(exercises.map(\.variant) == ["heavy (paused, comp grip)", "back-off (paused)"])
        // Same lift underneath: the variant is prescription, never identity.
        #expect(Set(exercises.map(\.exercise.id)).count == 1)
        #expect(exercises[0].displayName == "heavy (paused, comp grip)")
    }

    @Test("Supersets survive as one group")
    func preservesSupersets() throws {
        let fixture = try makeFixture()
        let original = block()
        try fixture.plans.save(original, userId: fixture.user.id)

        let loaded = try fixture.plans.fetchBlock(id: original.id)
        let groups = loaded?.program?[day(2026, 3, 4)]?.first?.exercises

        #expect(groups?.count == 1)
        #expect(groups?[0].count == 2)
        #expect(groups?[0][0].exercise.id == bench.id)
        #expect(groups?[0][1].exercise.id == row.id)
    }

    @Test("The plan orders blocks oldest first and derives the current one")
    func buildsPlan() throws {
        let fixture = try makeFixture()

        let first = WorkoutBlock(startDate: day(2026, 1, 1), endDate: day(2026, 2, 11))
        let second = WorkoutBlock(startDate: day(2026, 3, 1), endDate: day(2026, 4, 11))
        try fixture.plans.save(second, userId: fixture.user.id)
        try fixture.plans.save(first, userId: fixture.user.id)

        let plan = try fixture.plans.fetchPlan(userId: fixture.user.id)

        #expect(plan.blocks?.count == 2)
        #expect(plan.scheduledBlocks.first?.id == first.id)
        #expect(plan.currentBlock(asOf: day(2026, 3, 15), calendar: calendar)?.id == second.id)
    }

    @Test("Editing one day leaves the rest of the block untouched")
    func savingOneWorkoutDoesNotDisturbOthers() throws {
        // Workout Planner.md: a change in week 3 must not rewrite weeks 1 and 2.
        let fixture = try makeFixture()
        let original = block()
        try fixture.plans.save(original, userId: fixture.user.id)

        let edited = PlannedWorkout(
            date: day(2026, 3, 2),
            exercises: [[PlannedExercise(exercise: squat, sets: [PlannedSet(reps: 1, load: .percentOf(0.95, of: .goal))])]],
            notes: "Changed to a single"
        )
        try fixture.plans.save(edited, in: original.id)

        let loaded = try fixture.plans.fetchBlock(id: original.id)
        // The untouched day is exactly as it was.
        #expect(loaded?.program?[day(2026, 3, 4)]?.first?.allSets.count == 2)
        // The edited day gained a workout rather than replacing the existing one,
        // since it carries a different id — two-a-days are legal here.
        #expect(loaded?.program?[day(2026, 3, 2)]?.count == 2)
    }

    @Test("Planned workouts are found by day")
    func fetchesPlannedByDay() throws {
        let fixture = try makeFixture()
        try fixture.plans.save(block(), userId: fixture.user.id)

        #expect(try fixture.plans.fetchPlanned(on: day(2026, 3, 2)).count == 1)
        #expect(try fixture.plans.fetchPlanned(on: day(2026, 3, 3)).isEmpty)
    }

    @Test("Planned workouts are found across a date range, ordered and bounded")
    func fetchesPlannedByRange() throws {
        let fixture = try makeFixture()
        try fixture.plans.save(block(), userId: fixture.user.id)

        // Range covers both programmed days (Mar 2, Mar 4).
        let inRange = try fixture.plans.fetchPlanned(from: day(2026, 3, 1), to: day(2026, 3, 7))
        #expect(inRange.count == 2)
        #expect(inRange.first?.date == day(2026, 3, 2))
        #expect(inRange.last?.date == day(2026, 3, 4))

        // A range that excludes Mar 4 only returns Mar 2.
        let narrower = try fixture.plans.fetchPlanned(from: day(2026, 3, 1), to: day(2026, 3, 3))
        #expect(narrower.count == 1)
        #expect(narrower.first?.date == day(2026, 3, 2))

        // A range entirely outside the program returns nothing.
        #expect(try fixture.plans.fetchPlanned(from: day(2026, 4, 1), to: day(2026, 4, 30)).isEmpty)
    }

    @Test("Skipping and unskipping round-trip through fetchPlanned and fetchBlock")
    func skipRoundTrips() throws {
        let fixture = try makeFixture()
        let original = block()
        try fixture.plans.save(original, userId: fixture.user.id)
        let workoutID = original.program![day(2026, 3, 2)]!.first!.id

        try fixture.plans.markSkipped(workoutID: workoutID, at: day(2026, 3, 2))

        let viaRange = try fixture.plans.fetchPlanned(from: day(2026, 3, 1), to: day(2026, 3, 7))
        #expect(viaRange.first { $0.id == workoutID }?.skippedAt == day(2026, 3, 2))

        let viaBlock = try fixture.plans.fetchBlock(id: original.id)
        #expect(viaBlock?.program?[day(2026, 3, 2)]?.first?.skippedAt == day(2026, 3, 2))

        try fixture.plans.unmarkSkipped(workoutID: workoutID)
        let afterUnskip = try fixture.plans.fetchPlanned(from: day(2026, 3, 1), to: day(2026, 3, 7))
        #expect(afterUnskip.first { $0.id == workoutID }?.skippedAt == nil)
    }

    @Test("A pre-v4 row with no explicit skippedAt hydrates as nil")
    func missingSkippedAtHydratesAsNil() throws {
        // Guards the additive migration: a row written before v4_skippedWorkouts
        // existed (no skippedAt column value set) must still hydrate cleanly
        // rather than failing to decode.
        let fixture = try makeFixture()
        try fixture.plans.save(block(), userId: fixture.user.id)

        let loaded = try fixture.plans.fetchPlanned(on: day(2026, 3, 2))
        #expect(loaded.first?.skippedAt == nil)
    }

    @Test("Deleting a block leaves logged workouts standing")
    func deletingBlockKeepsHistory() throws {
        let fixture = try makeFixture()
        let original = block()
        try fixture.plans.save(original, userId: fixture.user.id)

        var session = WorkoutSession.start(
            from: original.program![day(2026, 3, 2)]!.first!,
            block: original,
            at: day(2026, 3, 2)
        )
        session.completeSet(id: session.workout.allSets[0].id, at: day(2026, 3, 2))
        session.finish(at: day(2026, 3, 2))
        try fixture.workouts.save(session.workout, blockId: original.id)

        try fixture.plans.deleteBlock(id: original.id)

        // Design.md's safety requirement: programming changes never destroy what
        // was actually lifted.
        let survived = try fixture.workouts.fetch(id: session.workout.id)
        #expect(survived != nil)
        #expect(survived?.allSets.count == 1)
        #expect(survived?.allSets.first?.plannedFrom != nil)
    }

    @Test("Logged workouts attach onto a block for adherence")
    func attachesLoggedWorkouts() throws {
        let fixture = try makeFixture()
        let original = block()
        try fixture.plans.save(original, userId: fixture.user.id)

        var session = WorkoutSession.start(
            from: original.program![day(2026, 3, 2)]!.first!,
            at: day(2026, 3, 2)
        )
        session.completeSet(id: session.workout.allSets[0].id, at: day(2026, 3, 2))
        session.finish(at: day(2026, 3, 2))
        try fixture.workouts.save(session.workout, blockId: original.id)

        let loaded = try fixture.plans.fetchBlock(id: original.id)!
        #expect(loaded.workouts == nil)  // not fetched by default

        let attached = try fixture.plans.attachingLoggedWorkouts(to: loaded, using: fixture.workouts)
        #expect(attached.workouts(on: day(2026, 3, 2), calendar: calendar).count == 1)
        #expect(attached.program(on: day(2026, 3, 2), calendar: calendar).count == 1)
    }
}

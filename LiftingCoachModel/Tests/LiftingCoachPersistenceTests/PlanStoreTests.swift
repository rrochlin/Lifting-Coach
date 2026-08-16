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

import Foundation
import Testing
@testable import LiftingCoachModel

private let calendar = Calendar(identifier: .gregorian)

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

@Suite("WorkoutPlan block derivation")
struct WorkoutPlanTests {

    /// The behavior Concepts.md is explicit about: a block whose planned end has
    /// passed stays current until the *next* block actually starts, so it never
    /// disappears from view on a slipped schedule.
    @Test("A block that has run past its endDate is still the current block")
    func overrunBlockStaysCurrent() {
        let block = WorkoutBlock(
            startDate: day(2026, 1, 1),
            endDate: day(2026, 2, 12)
        )
        let plan = WorkoutPlan(blocks: [block])

        let current = plan.currentBlock(asOf: day(2026, 3, 1), calendar: calendar)
        #expect(current?.id == block.id)
    }

    @Test("The current block is the latest one already started")
    func picksLatestStartedBlock() {
        let first = WorkoutBlock(startDate: day(2026, 1, 1))
        let second = WorkoutBlock(startDate: day(2026, 2, 15))
        let third = WorkoutBlock(startDate: day(2026, 4, 1))
        let plan = WorkoutPlan(blocks: [third, first, second])  // deliberately unsorted

        let current = plan.currentBlock(asOf: day(2026, 3, 1), calendar: calendar)
        #expect(current?.id == second.id)
    }

    @Test("A block starting today is already current")
    func blockStartingTodayIsCurrent() {
        let block = WorkoutBlock(startDate: day(2026, 3, 1))
        let plan = WorkoutPlan(blocks: [block])

        #expect(plan.currentBlock(asOf: day(2026, 3, 1), calendar: calendar)?.id == block.id)
    }

    @Test("No block is current before the plan starts")
    func noCurrentBlockBeforePlanStarts() {
        let plan = WorkoutPlan(blocks: [WorkoutBlock(startDate: day(2026, 5, 1))])

        #expect(plan.currentBlock(asOf: day(2026, 1, 1), calendar: calendar) == nil)
    }

    @Test("nextBlock is the one after current, even though it hasn't started")
    func nextBlockFollowsCurrent() {
        let current = WorkoutBlock(startDate: day(2026, 1, 1))
        let upcoming = WorkoutBlock(startDate: day(2026, 4, 1))
        let plan = WorkoutPlan(blocks: [current, upcoming])

        let next = plan.nextBlock(asOf: day(2026, 2, 1), calendar: calendar)
        #expect(next?.id == upcoming.id)
    }

    @Test("nextBlock is nil on the final block")
    func nextBlockNilAtEndOfPlan() {
        let plan = WorkoutPlan(blocks: [WorkoutBlock(startDate: day(2026, 1, 1))])

        #expect(plan.nextBlock(asOf: day(2026, 2, 1), calendar: calendar) == nil)
    }

    @Test("Blocks with no startDate aren't schedulable")
    func unscheduledBlocksIgnored() {
        let scheduled = WorkoutBlock(startDate: day(2026, 1, 1))
        let draft = WorkoutBlock(startDate: nil)
        let plan = WorkoutPlan(blocks: [scheduled, draft])

        #expect(plan.scheduledBlocks.count == 1)
        #expect(plan.currentBlock(asOf: day(2026, 2, 1), calendar: calendar)?.id == scheduled.id)
    }
}

@Suite("WorkoutBlock")
struct WorkoutBlockTests {

    // Jan 1 through Feb 11 inclusive is 42 days — a 6-week block.
    @Test("Progress reports 1-based day and week within the block")
    func progressCounts() {
        let block = WorkoutBlock(startDate: day(2026, 1, 1), endDate: day(2026, 2, 11))

        let progress = block.progress(asOf: day(2026, 1, 15), calendar: calendar)
        #expect(progress?.dayIndex == 15)
        #expect(progress?.weekIndex == 3)
        #expect(progress?.totalWeeks == 6)
    }

    @Test("Progress keeps counting past endDate rather than clamping")
    func progressOverruns() {
        let block = WorkoutBlock(startDate: day(2026, 1, 1), endDate: day(2026, 2, 11))

        let progress = block.progress(asOf: day(2026, 2, 25), calendar: calendar)
        #expect(progress?.weekIndex == 8)
        #expect(progress?.totalWeeks == 6)
    }

    @Test("Progress has no totalWeeks when the block has no planned end")
    func progressWithoutEndDate() {
        let block = WorkoutBlock(startDate: day(2026, 1, 1))

        let progress = block.progress(asOf: day(2026, 1, 15), calendar: calendar)
        #expect(progress?.dayIndex == 15)
        #expect(progress?.totalWeeks == nil)
    }

    @Test("Rest time falls back set → block default → app default")
    func restTimeFallback() {
        let block = WorkoutBlock(defaultRestTimes: [.working: 180])

        let explicit = PlannedSet(type: .working, restTime: 240)
        #expect(block.restTime(for: explicit) == 240)

        let blockDefaulted = PlannedSet(type: .working)
        #expect(block.restTime(for: blockDefaulted) == 180)

        let appDefaulted = PlannedSet(type: .warmup)
        #expect(block.restTime(for: appDefaulted, appDefault: 90) == 90)
    }

    @Test("Workouts and program are looked up by start of day")
    func lookupNormalizesToStartOfDay() {
        let target = day(2026, 1, 5)
        let logged = Workout(startTime: target)
        let block = WorkoutBlock(workouts: [target: [logged]])

        let midAfternoon = calendar.date(byAdding: .hour, value: 15, to: target)!
        #expect(block.workouts(on: midAfternoon, calendar: calendar).count == 1)
    }
}

@Suite("User")
struct UserTests {

    @Test("A goal percentage resolves against the goal max, plate-rounded")
    func resolvesPercentOfGoal() {
        let bench = ExerciseCatalog.seed[1]
        let user = User(
            name: "Rob",
            email: "steelr3@gmail.com",
            goalMaxes: [bench.id: GoalMax(weight: Measurement(value: 365, unit: .pounds))]
        )

        // 0.725 * 365 = 264.625, rounded to the 5 lb plate increment — the same
        // MROUND(x, 5) the source spreadsheet applies.
        let resolved = user.resolvedWeight(for: .percentOf(0.725, of: .goal), exercise: bench)
        #expect(resolved?.value == 265)
        #expect(resolved?.unit == UnitMass.pounds)
    }

    @Test("An achieved percentage resolves against the newest achieved max")
    func resolvesPercentOfAchieved() {
        let bench = ExerciseCatalog.seed[1]
        let user = User(
            name: "Rob",
            email: "steelr3@gmail.com",
            achievedMaxes: [bench.id: [
                AchievedMax(weight: Measurement(value: 300, unit: .pounds), date: day(2026, 1, 1)),
                AchievedMax(weight: Measurement(value: 315, unit: .pounds), date: day(2026, 6, 1)),
            ]]
        )

        let resolved = user.resolvedWeight(for: .percentOf(0.8, of: .achieved), exercise: bench)
        // 0.8 * 315 = 252 → 250 at the 5 lb increment; the newer max wins.
        #expect(resolved?.value == 250)
    }

    @Test("A percentage of a max the user doesn't have stays unresolved")
    func percentWithoutMaxIsNil() {
        let user = User(name: "Rob", email: "steelr3@gmail.com")

        #expect(user.resolvedWeight(for: .percentOf(0.8, of: .goal), exercise: ExerciseCatalog.seed[1]) == nil)
        #expect(user.resolvedWeight(for: .percentOf(0.8, of: .achieved), exercise: ExerciseCatalog.seed[1]) == nil)
    }

    @Test("Theoretical max is unresolvable until an estimation model exists")
    func theoreticalIsNotResolved() {
        let bench = ExerciseCatalog.seed[1]
        let user = User(
            name: "Rob",
            email: "steelr3@gmail.com",
            goalMaxes: [bench.id: GoalMax(weight: Measurement(value: 365, unit: .pounds))]
        )

        #expect(user.resolvedWeight(for: .percentOf(0.8, of: .theoretical), exercise: bench) == nil)
    }

    @Test("Goal and achieved maxes are distinct data points")
    func maxKindsAreDistinct() {
        let bench = ExerciseCatalog.seed[1]
        let user = User(
            name: "Rob",
            email: "steelr3@gmail.com",
            achievedMaxes: [bench.id: [AchievedMax(weight: Measurement(value: 315, unit: .pounds), date: day(2026, 1, 1))]],
            goalMaxes: [bench.id: GoalMax(weight: Measurement(value: 365, unit: .pounds))]
        )

        #expect(user.max(.achieved, for: bench.id)?.value == 315)
        #expect(user.max(.goal, for: bench.id)?.value == 365)
    }

    @Test("currentBodyWeight is the most recent entry")
    func latestBodyWeight() {
        let user = User(
            name: "Rob",
            email: "steelr3@gmail.com",
            bodyWeight: [
                day(2026, 1, 1): Measurement(value: 200, unit: .pounds),
                day(2026, 3, 1): Measurement(value: 195, unit: .pounds),
                day(2026, 2, 1): Measurement(value: 198, unit: .pounds),
            ]
        )

        #expect(user.currentBodyWeight?.value == 195)
    }
}

@Suite("Workout")
struct WorkoutTests {

    @Test("allSets flattens supersets and exercises")
    func flattensSets() {
        let squat = ExerciseCatalog.seed[0]
        let bench = ExerciseCatalog.seed[1]
        let workout = Workout(exercises: [
            [WorkoutExercise(exercise: squat, sets: [WorkoutSet(reps: 5), WorkoutSet(reps: 5)])],
            // a superset group: two exercises performed together
            [
                WorkoutExercise(exercise: bench, sets: [WorkoutSet(reps: 8)]),
                WorkoutExercise(exercise: ExerciseCatalog.seed[4], sets: [WorkoutSet(reps: 8)]),
            ],
        ])

        #expect(workout.allSets.count == 4)
    }

    @Test("A started but unfinished workout is in progress")
    func inProgressState() {
        #expect(Workout(startTime: day(2026, 1, 1)).isInProgress)
        #expect(!Workout(startTime: day(2026, 1, 1), endTime: day(2026, 1, 1)).isInProgress)
        #expect(!Workout().isInProgress)
    }
}

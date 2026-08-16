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

/// A Monday, so week/dayOfWeek offsets line up with the program's Mon-anchored
/// weeks.
private let blockStart = day(2026, 8, 17)

@Suite("Program import")
struct ProgramImporterTests {

    private func importBundled() throws -> (AppDatabase, User, ProgramImporter.Result) {
        let database = try AppDatabase.inMemory()
        try ExerciseStore(database).save(ExerciseCatalog.seed)
        let users = UserStore(database, calendar: calendar)
        let user = try users.localUser()

        let result = try ProgramImporter(database, calendar: calendar).importProgram(
            try ProgramImporter.bundledBlock1,
            for: user.id,
            startDate: blockStart
        )
        return (database, try users.localUser(), result)
    }

    @Test("The full 12-week block imports with nothing dropped")
    func importsWholeBlock() throws {
        let (database, _, result) = try importBundled()

        // Counts verified against the source sheet: 69 days, SUM(Sets) = 644.
        #expect(result.dayCount == 69)
        #expect(result.setCount == 644)
        // canonical big three plus every variation that programs off them
        #expect(result.goalMaxCount >= 3)

        let plans = PlanStore(database, calendar: calendar)
        let loaded = try plans.fetchBlock(id: result.block.id)
        #expect(loaded != nil)
        #expect(loaded?.startDate == blockStart)

        let persistedSets = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM plannedSet")
        }
        #expect(persistedSets == 644)
    }

    @Test("The sheet's maxes import as goals, not achieved lifts")
    func maxesImportAsGoals() throws {
        let (_, user, _) = try importBundled()

        // Plan!A8: "goal maxes (targets, not all verified)" — importing them as
        // achieved would fabricate lifts that never happened.
        let squat = ExerciseCatalog.seed[0]
        #expect(user.max(.goal, for: squat.id)?.value == 495)
        #expect(user.max(.achieved, for: squat.id) == nil)
        #expect(user.max(.goal, for: 2)?.value == 365)   // bench
        #expect(user.max(.goal, for: 3)?.value == 555)   // deadlift
    }

    @Test("Week and day place workouts on the right calendar dates")
    func schedulesOntoCalendar() throws {
        let (database, _, _) = try importBundled()
        let plans = PlanStore(database, calendar: calendar)

        // Week 1 Monday = the start date itself.
        #expect(try plans.fetchPlanned(on: blockStart).count == 1)
        // Week 2 Monday = start + 7.
        let week2 = calendar.date(byAdding: .day, value: 7, to: blockStart)!
        #expect(try plans.fetchPlanned(on: week2).count == 1)
        // Week 1 Saturday: the 6-day program trains Mon-Fri + Sun — no Saturday.
        let saturday = calendar.date(byAdding: .day, value: 5, to: blockStart)!
        #expect(try plans.fetchPlanned(on: saturday).isEmpty)
    }

    @Test("A main lift carries both axes: goal-percent load and an RPE target")
    func mainLiftCarriesBothAxes() throws {
        let (database, user, _) = try importBundled()
        let plans = PlanStore(database, calendar: calendar)

        let monday = try #require(try plans.fetchPlanned(on: blockStart).first)
        let benchHeavy = try #require(
            monday.exercises?.flatMap { $0 }.first { $0.exercise.name.hasPrefix("Bench press — heavy") }
        )

        // Load: 72.5% of the bench goal (365) → 264.625 → 265 at the plate step.
        let set = try #require(benchHeavy.sets?.first)
        #expect(set.load == .percentOf(0.725, of: .goal))
        #expect(user.resolvedWeight(for: set.load!, exercise: benchHeavy.exercise)?.value == 265)

        // Effort: RPE 7 as one instruction at the exercise level.
        #expect(benchHeavy.effort == EffortTarget(rpe: 7))
        #expect(benchHeavy.resolvedEffort(for: set) == EffortTarget(rpe: 7))
    }

    @Test("An accessory imports as effort-only, with no load axis")
    func accessoryIsEffortOnly() throws {
        let (database, _, _) = try importBundled()
        let plans = PlanStore(database, calendar: calendar)

        let monday = try #require(try plans.fetchPlanned(on: blockStart).first)
        let accessory = try #require(
            monday.exercises?.flatMap { $0 }.first { $0.exercise.name.hasPrefix("Triceps") }
        )

        // The sheet gives accessories no weight at all — the RPE is the whole
        // prescription. Importing the old way (rpe-as-load) would have invented
        // a load axis that doesn't exist.
        #expect(accessory.effort != nil)
        #expect(accessory.sets?.allSatisfy { $0.load == nil } == true)
    }

    @Test("Importing twice doesn't duplicate the catalog")
    func reimportReusesCatalog() throws {
        let (database, user, first) = try importBundled()

        let exercisesBefore = try ExerciseStore(database).fetchAll().count
        try ProgramImporter(database, calendar: calendar).importProgram(
            try ProgramImporter.bundledBlock1,
            for: user.id,
            startDate: day(2027, 1, 4)
        )

        // Same names → same catalog entries; only the block itself is new.
        #expect(try ExerciseStore(database).fetchAll().count == exercisesBefore)
        let blocks = try PlanStore(database, calendar: calendar).fetchPlan(userId: user.id)
        #expect(blocks.blocks?.count == 2)
        _ = first
    }
}

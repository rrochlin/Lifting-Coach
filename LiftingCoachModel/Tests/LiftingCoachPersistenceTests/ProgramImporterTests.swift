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
        // Catalog first, mirroring AppEnvironment.bootstrap — the program
        // import resolves its exercises onto catalog entries, so importing it
        // against an empty catalog would exercise only the fallback path.
        try CatalogImporter(database).importAndReconcile(try CatalogImporter.bundledCatalog)
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

        // 69 days, and the sheet's own SUM(Sets) of 644 — plus 27 more, because
        // "Triceps + biceps" is one sheet row but two exercises performed
        // together: each slot gets the row's 3 sets, so 9 occurrences of that
        // row contribute 27 extra. The sheet under-counts it; the program
        // genuinely prescribes both.
        #expect(result.dayCount == 69)
        #expect(result.setCount == 671)
        // canonical big three plus every variation that programs off them
        #expect(result.goalMaxCount >= 3)

        let plans = PlanStore(database, calendar: calendar)
        let loaded = try plans.fetchBlock(id: result.block.id)
        #expect(loaded != nil)
        #expect(loaded?.startDate == blockStart)

        let persistedSets = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM plannedSet")
        }
        #expect(persistedSets == 671)
    }

    @Test("The sheet's maxes import as goals against canonical catalog lifts")
    func maxesImportAsGoals() throws {
        let (database, user, _) = try importBundled()
        let exercises = ExerciseStore(database)

        // Plan!A8: "goal maxes (targets, not all verified)" — importing them as
        // achieved would fabricate lifts that never happened.
        //
        // The goals land on the vendored catalog's canonical entries, not on
        // sheet-derived duplicates: the whole point of the program→catalog
        // mapping is that "Squat — volume (comp stance)" IS Barbell Squat.
        let squat = try #require(try exercises.fetch(sourceSlug: "Barbell_Squat"))
        let bench = try #require(try exercises.fetch(sourceSlug: "Barbell_Bench_Press_-_Medium_Grip"))
        let deadlift = try #require(try exercises.fetch(sourceSlug: "Barbell_Deadlift"))

        #expect(user.max(.goal, for: squat.id)?.value == 495)
        #expect(user.max(.goal, for: bench.id)?.value == 365)
        #expect(user.max(.goal, for: deadlift.id)?.value == 555)
        #expect(user.max(.achieved, for: squat.id) == nil)
    }

    @Test("Program exercises resolve onto the catalog instead of duplicating it")
    func resolvesOntoCatalog() throws {
        let (database, _, _) = try importBundled()
        let exercises = ExerciseStore(database)
        let all = try exercises.fetchAll()

        // The sheet's variation names must not become catalog entries of their
        // own — that pollution is what the mapping exists to prevent.
        for name in [
            "Squat — volume (comp stance)",
            "Bench volume — Spoto press (1\" off chest)",
            "Deadlift — heavy (straight bar)",
        ] {
            #expect(!all.contains { $0.name == name }, "\(name) should resolve to a catalog entry")
        }

        // "Triceps + biceps" is one sheet row but two slots, so it becomes two
        // open-choice placeholders the lifter fills independently.
        let triceps = try #require(all.first { $0.name == "Triceps" })
        let biceps = try #require(all.first { $0.name == "Biceps" })
        #expect(triceps.isOpenChoice)
        #expect(biceps.isOpenChoice)
        #expect(triceps.id != biceps.id)
    }

    @Test("Resolving onto the catalog keeps the program's own wording as a variant")
    func keepsProgramWordingAsVariant() throws {
        let (database, _, _) = try importBundled()
        let plans = PlanStore(database, calendar: calendar)

        // Monday prescribes heavy paused bench *and* its back-off sets. Both
        // are Barbell Bench Press — correctly, they share a max — so without a
        // variant the day would read as the same exercise listed twice.
        let monday = try #require(try plans.fetchPlanned(on: blockStart).first)
        let bench = (monday.exercises?.flatMap { $0 } ?? []).filter {
            $0.exercise.sourceSlug == "Barbell_Bench_Press_-_Medium_Grip"
        }
        #expect(bench.count == 2)
        #expect(Set(bench.map(\.exercise.id)).count == 1)
        #expect(
            Set(bench.map(\.displayName)) == [
                "Bench press — heavy (paused, comp grip)",
                "Bench — back-off (paused)",
            ]
        )
    }

    @Test("An open-choice slot carries no variant — its name is already the program's")
    func openChoiceSlotsHaveNoVariant() throws {
        let (database, _, _) = try importBundled()
        let plans = PlanStore(database, calendar: calendar)

        let monday = try #require(try plans.fetchPlanned(on: blockStart).first)
        let triceps = try #require(
            monday.exercises?.flatMap { $0 }.first { $0.exercise.isOpenChoice }
        )

        #expect(triceps.variant == nil)
        #expect(triceps.displayName == triceps.exercise.name)
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

        // The sheet's "Bench press — heavy (paused, comp grip)" now resolves to
        // the canonical catalog bench press, so look it up by that rather than
        // by the spreadsheet's own name for the variation.
        let monday = try #require(try plans.fetchPlanned(on: blockStart).first)
        let benchHeavy = try #require(
            monday.exercises?.flatMap { $0 }.first {
                $0.exercise.sourceSlug == "Barbell_Bench_Press_-_Medium_Grip"
            }
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

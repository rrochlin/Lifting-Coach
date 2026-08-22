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

@Suite("Program loading")
struct ProgramLoaderTests {

    private func loadBundled() throws -> (AppDatabase, User, ProgramLoader.Result) {
        let database = try AppDatabase.inMemory()
        // Catalog first, mirroring AppEnvironment.bootstrap — the program names
        // its exercises by catalog slug, so there has to be a catalog for those
        // slugs to name.
        try CatalogImporter(database).importCatalog(try CatalogImporter.bundledCatalog)
        let users = UserStore(database, calendar: calendar)
        let user = try users.localUser()

        let result = try ProgramLoader(database, calendar: calendar).load(
            try ProgramLoader.bundledBlock1,
            for: user.id,
            startDate: blockStart
        )
        return (database, try users.localUser(), result)
    }

    @Test("The full 12-week block loads with nothing dropped")
    func loadsWholeBlock() throws {
        let (database, _, result) = try loadBundled()

        // 69 days, and the sheet's own SUM(Sets) of 644 — plus 54 more, because
        // two sheet rows each call for two exercises performed together
        // ("Triceps + biceps", "Lat pulldown / cable row + face pulls"). Each
        // slot gets the row's 3 sets, and each row appears 9 times, so the two
        // contribute 27 extra apiece. The sheet under-counts them; the program
        // genuinely prescribes both halves.
        #expect(result.dayCount == 69)
        #expect(result.setCount == 698)

        let plans = PlanStore(database, calendar: calendar)
        let loaded = try plans.fetchBlock(id: result.block.id)
        #expect(loaded != nil)
        #expect(loaded?.startDate == blockStart)

        // SUM, not COUNT. A row prescribes `setCount` sets — the program is
        // written "3x5 @ 72.5%" and stored that way — so 698 sets live in 209
        // rows. Counting rows here would be asserting how the file happens to
        // be punctuated rather than how much work it prescribes.
        let persistedSets = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT SUM(setCount) FROM plannedSet")
        }
        #expect(persistedSets == 698)

        let persistedRows = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM plannedSet")
        }
        #expect(persistedRows == 209)
    }

    @Test("The program's maxes load as goals against the lifts they govern")
    func maxesLoadAsGoals() throws {
        let (database, user, result) = try loadBundled()
        let exercises = ExerciseStore(database)

        // Plan!A8: "goal maxes (targets, not all verified)" — loading them as
        // achieved would fabricate lifts that never happened.
        let squat = try #require(try exercises.fetch(sourceSlug: "Barbell_Squat"))
        let bench = try #require(try exercises.fetch(sourceSlug: "Barbell_Bench_Press_-_Medium_Grip"))
        let deadlift = try #require(try exercises.fetch(sourceSlug: "Barbell_Deadlift"))
        let deficit = try #require(try exercises.fetch(sourceSlug: "Deficit_Deadlift"))

        #expect(user.max(.goal, for: squat.id)?.value == 495)
        #expect(user.max(.goal, for: bench.id)?.value == 365)
        #expect(user.max(.goal, for: deadlift.id)?.value == 555)
        // The deficit deadlift's percentages multiply the deadlift goal too, so
        // the file lists it under that max explicitly rather than leaving the
        // loader to work out which lift a variation belongs to.
        #expect(user.max(.goal, for: deficit.id)?.value == 555)
        #expect(result.goalMaxCount == 4)

        #expect(user.max(.achieved, for: squat.id) == nil)
    }

    @Test("Named exercises are catalog entries, not new rows named after the program")
    func namedExercisesAreCatalogEntries() throws {
        let (database, _, _) = try loadBundled()
        let all = try ExerciseStore(database).fetchAll()

        // The sheet's variation names must not become catalog entries of their
        // own — naming an exercise by slug is what prevents that.
        for name in [
            "Squat — volume (comp stance)",
            "Bench volume — Spoto press (1\" off chest)",
            "Deadlift — heavy (straight bar)",
        ] {
            #expect(!all.contains { $0.name == name }, "\(name) should be a catalog entry")
        }

        // "Triceps + biceps" is one sheet row calling for two exercises, so the
        // program declares two open slots the lifter fills independently.
        let triceps = try #require(all.first { $0.name == "Triceps" })
        let biceps = try #require(all.first { $0.name == "Biceps" })
        #expect(triceps.isOpenChoice)
        #expect(biceps.isOpenChoice)
        #expect(triceps.id != biceps.id)
    }

    @Test("An open slot carries the movements the program suggested")
    func openSlotsCarrySuggestions() throws {
        let (database, _, _) = try loadBundled()
        let all = try ExerciseStore(database).fetchAll()

        let triceps = try #require(all.first { $0.name == "Triceps" })
        #expect(triceps.suggestions == ["Overhead Extension", "Pushdown"])

        // Suggestions are optional — the program floats none for a plain
        // cardio slot, and an empty list would read as "nothing is suitable".
        let cardio = try #require(all.first { $0.name == "Cardio" })
        #expect(cardio.isOpenChoice)
        #expect(cardio.suggestions == nil)
    }

    @Test("Every suggested movement is findable in the catalog")
    func suggestionsResolveAgainstTheCatalog() throws {
        // A suggestion chip is a *search shortcut* — tapping one types it into
        // the picker's search field. So a suggestion the catalog has no word
        // for isn't a harmless bit of prose, it's a button that empties the
        // screen. That's what happened on the Tuesday deadlift day: the row
        // slot suggested "Chest-supported row" and "Seal row", the catalog
        // contains neither, and the lifter got a blank list mid-workout.
        //
        // The coach's own wording is not lost by fixing this — it lives in
        // `PlannedExercise.variant`, which is what the tracker shows as the
        // exercise's title. This is the translation layer, and translating is
        // the job (see `ProgramLoader`'s doc comment).
        let (database, _, _) = try loadBundled()
        let all = try ExerciseStore(database).fetchAll()
        // Through the picker's own search rather than a substring test, so this
        // asks what the chip actually does. It used to check `contains`, which
        // has since stopped being how the picker searches — a guard that
        // measures something the app no longer does can pass while the button
        // it was written for is broken.
        let index = ExerciseSearchIndex(all)

        var checked = 0
        for slot in all where slot.isOpenChoice {
            for suggestion in slot.suggestions ?? [] {
                #expect(!index.ranked(suggestion).isEmpty,
                        "\(slot.name): '\(suggestion)' finds nothing")
                checked += 1
            }
        }
        // Guards the guard: a loader that stopped carrying suggestions at all
        // would otherwise make this test pass by having nothing to check.
        #expect(checked >= 12)
    }

    @Test("The program's own wording survives as a variant")
    func keepsProgramWordingAsVariant() throws {
        let (database, _, _) = try loadBundled()
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

    @Test("An open slot reads as the program worded it, not as the slot's own name")
    func openSlotsKeepProgramWording() throws {
        let (database, _, _) = try loadBundled()
        let plans = PlanStore(database, calendar: calendar)

        // The exercise is a reusable "Cardio" slot, but Wednesday says "Walk
        // with wife (recovery)" and that's what should be on screen — the
        // wording is the instruction.
        let wednesday = calendar.date(byAdding: .day, value: 2, to: blockStart)!
        let workout = try #require(try plans.fetchPlanned(on: wednesday).first)
        let walk = try #require(
            workout.exercises?.flatMap { $0 }.first { $0.exercise.name == "Cardio" }
        )

        #expect(walk.exercise.isOpenChoice)
        #expect(walk.displayName == "Walk with wife (recovery)")
    }

    @Test("A row calling for two exercises expands to two slots that read distinctly")
    func multiSlotRowsReadDistinctly() throws {
        let (database, _, _) = try loadBundled()
        let plans = PlanStore(database, calendar: calendar)

        // Thursday's "Lat pulldown / cable row + face pulls" is one sheet row
        // asking for two exercises. They travel together, so they're one
        // superset group — but stamping the row's wording on both would print
        // the same line twice, which is the thing `variant` exists to prevent.
        let thursday = calendar.date(byAdding: .day, value: 3, to: blockStart)!
        let workout = try #require(try plans.fetchPlanned(on: thursday).first)
        let pair = try #require(workout.exercises?.first { $0.count > 1 })

        #expect(pair.count == 2)
        #expect(Set(pair.map(\.displayName)) == ["Upper back", "Rear delts"])
        #expect(pair.allSatisfy { $0.exercise.isOpenChoice })
        // Two slots, filled and tracked independently.
        #expect(Set(pair.map(\.exercise.id)).count == 2)
    }

    @Test("Week and day place workouts on the right calendar dates")
    func schedulesOntoCalendar() throws {
        let (database, _, _) = try loadBundled()
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
        let (database, user, _) = try loadBundled()
        let plans = PlanStore(database, calendar: calendar)

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

    @Test("An accessory loads as effort-only, with no load axis")
    func accessoryIsEffortOnly() throws {
        let (database, _, _) = try loadBundled()
        let plans = PlanStore(database, calendar: calendar)

        let monday = try #require(try plans.fetchPlanned(on: blockStart).first)
        let accessory = try #require(
            monday.exercises?.flatMap { $0 }.first { $0.exercise.name == "Triceps" }
        )

        // The sheet gives accessories no weight at all — the RPE is the whole
        // prescription. A load axis here would be invented.
        #expect(accessory.effort != nil)
        #expect(accessory.sets?.allSatisfy { $0.load == nil } == true)
    }

    @Test("A slug the catalog doesn't have fails the load instead of dropping the exercise")
    func unknownSlugThrows() throws {
        let database = try AppDatabase.inMemory()
        try CatalogImporter(database).importCatalog(try CatalogImporter.bundledCatalog)
        let user = try UserStore(database, calendar: calendar).localUser()

        // Silently skipping would leave a plan that looks complete while a
        // day's work quietly went missing (Core Tenets §10).
        let program = Data("""
        {
          "name": "Broken", "weeks": 1, "goalMaxes": [], "openChoiceExercises": [],
          "days": [{ "week": 1, "dayOfWeek": 1, "label": "Mon", "exercises": [[
            { "exercise": "Barbell_Moon_Press", "sets": [{ "reps": 5 }] }
          ]]}]
        }
        """.utf8)

        #expect(throws: ProgramLoader.LoadError.unknownExercise("Barbell_Moon_Press")) {
            try ProgramLoader(database, calendar: calendar).load(
                program, for: user.id, startDate: blockStart
            )
        }
    }

    @Test("Loading twice doesn't duplicate the catalog")
    func reloadReusesCatalog() throws {
        let (database, user, _) = try loadBundled()

        let exercisesBefore = try ExerciseStore(database).fetchAll().count
        try ProgramLoader(database, calendar: calendar).load(
            try ProgramLoader.bundledBlock1,
            for: user.id,
            startDate: day(2027, 1, 4)
        )

        // Named lifts are already catalog entries and open slots are reused by
        // name, so a second load adds only the block itself.
        #expect(try ExerciseStore(database).fetchAll().count == exercisesBefore)
        let blocks = try PlanStore(database, calendar: calendar).fetchPlan(userId: user.id)
        #expect(blocks.blocks?.count == 2)
    }
}

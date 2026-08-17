import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

@Suite("Catalog import")
struct CatalogImporterTests {

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    @Test("The vendored catalog imports in full")
    func importsWholeCatalog() throws {
        let database = try makeDatabase()
        let result = try CatalogImporter(database).importAndReconcile(try CatalogImporter.bundledCatalog)

        // 873 at vendoring time — not asserting the exact figure so a future
        // re-vendor doesn't need this test touched, just that it's a real bulk
        // import and not, say, one record surviving a parsing bug.
        #expect(result.importedCount > 800)

        let all = try ExerciseStore(database).fetchAll()
        #expect(all.count == result.importedCount)
    }

    @Test("Imported entries carry real catalog metadata")
    func importedEntriesHaveMetadata() throws {
        let database = try makeDatabase()
        try CatalogImporter(database).importAndReconcile(try CatalogImporter.bundledCatalog)

        let all = try ExerciseStore(database).fetchAll()
        let deadlift = try #require(all.first { $0.name == "Barbell Deadlift" })

        #expect(deadlift.sourceSlug != nil)
        #expect(deadlift.primaryMuscles?.isEmpty == false)
        #expect(deadlift.category != nil)
        #expect(deadlift.muscleGroup != "Other")  // derived from a real primary muscle
    }

    @Test("Re-importing upserts by source identity instead of duplicating")
    func reimportIsIdempotent() throws {
        let database = try makeDatabase()
        let store = ExerciseStore(database)
        let importer = CatalogImporter(database)

        try importer.importAndReconcile(try CatalogImporter.bundledCatalog)
        let countAfterFirst = try store.fetchAll().count
        let deadlift = try #require(try store.fetchAll().first { $0.name == "Barbell Deadlift" })

        try importer.importAndReconcile(try CatalogImporter.bundledCatalog)
        let countAfterSecond = try store.fetchAll().count

        #expect(countAfterFirst == countAfterSecond)
        // Same id preserved across the re-import — anything that referenced
        // this exercise (a planned set, a logged max) still points at it.
        let deadliftAgain = try #require(try store.fetch(id: deadlift.id))
        #expect(deadliftAgain.name == "Barbell Deadlift")
    }

    @Test("Reconciliation enriches an unlinked exercise without changing its identity")
    func reconciliationPreservesIdentity() throws {
        let database = try makeDatabase()
        let store = ExerciseStore(database)

        // A program-style exercise: specific, non-canonical name, no metadata —
        // exactly what ProgramImporter creates from a spreadsheet row.
        let programExercise = Exercise(id: 500, name: "Deadlift — heavy (straight bar)", muscleGroup: "Posterior Chain")
        try store.save(programExercise)

        let result = try CatalogImporter(database).importAndReconcile(try CatalogImporter.bundledCatalog)
        #expect(result.enrichedCount >= 1)

        let enriched = try #require(try store.fetch(id: 500))
        // Identity untouched — still the program's own row and own name.
        #expect(enriched.id == 500)
        #expect(enriched.name == "Deadlift — heavy (straight bar)")
        // Metadata filled in from whatever it matched, tracked as provenance
        // (matchedSlug) rather than identity (sourceSlug stays nil — this row
        // never became the exercise it borrowed metadata from).
        #expect(enriched.primaryMuscles?.isEmpty == false)
        #expect(enriched.matchedSlug != nil)
        #expect(enriched.sourceSlug == nil)
    }

    @Test("Two different exercises matching the same canonical entry doesn't violate a uniqueness constraint")
    func multipleMatchesToSameCanonicalEntryAreFine() throws {
        // The real case this guards: "Bench press — heavy" and "Bench volume
        // — Spoto press" both legitimately match "Barbell Bench Press -
        // Medium Grip". sourceSlug is unique; matchedSlug must not be, or this
        // throws a constraint violation.
        let database = try makeDatabase()
        let store = ExerciseStore(database)
        try store.save(Exercise(id: 601, name: "Bench press — heavy (paused, comp grip)", muscleGroup: "Chest"))
        try store.save(Exercise(id: 602, name: "Bench volume — Larsen press (no leg drive)", muscleGroup: "Chest"))

        let result = try CatalogImporter(database).importAndReconcile(try CatalogImporter.bundledCatalog)
        #expect(result.enrichedCount == 2)

        let first = try #require(try store.fetch(id: 601))
        let second = try #require(try store.fetch(id: 602))
        #expect(first.matchedSlug != nil)
        #expect(first.matchedSlug == second.matchedSlug)
    }

    @Test("An exercise with no honest match is left alone and reported")
    func unmatchableExerciseIsReported() throws {
        let database = try makeDatabase()
        let store = ExerciseStore(database)

        try store.save(Exercise(id: 501, name: "Triceps + biceps", muscleGroup: "Arms"))
        try store.save(Exercise(id: 502, name: "Walk with wife (recovery)", muscleGroup: "Conditioning"))

        let result = try CatalogImporter(database).importAndReconcile(try CatalogImporter.bundledCatalog)

        #expect(result.unmatchedNames.contains("Triceps + biceps"))

        let untouched = try #require(try store.fetch(id: 501))
        #expect(untouched.primaryMuscles == nil)
        #expect(untouched.sourceSlug == nil)
        // "Triceps + biceps" isn't a mis-named specific lift — it's a
        // coach's-choice slot, and gets flagged as one so achieved-max
        // tracking knows to leave it alone.
        #expect(untouched.isOpenChoice)
    }

    @Test("Reconciliation with nothing unenriched is a no-op")
    func noUnenrichedExercisesIsANoOp() throws {
        let database = try makeDatabase()
        let importer = CatalogImporter(database)

        // Nothing but the catalog itself — every row will have a sourceSlug,
        // so there's nothing left to reconcile against it.
        let result = try importer.importAndReconcile(try CatalogImporter.bundledCatalog)
        #expect(result.enrichedCount == 0)
        #expect(result.unmatchedNames.isEmpty)
    }
}

@Suite("Catalog import against the real program")
struct CatalogImporterRealProgramTests {

    /// Runs the same sequence AppEnvironment.bootstrap() does — the real
    /// Block1 program, then the real catalog — and checks the reconciliation
    /// outcome against what was verified by hand against the source data
    /// while building CatalogMatcher (see its doc comment).
    @Test("Reconciling the real Block 1 program leaves only the genuinely ambiguous entries unmatched")
    func reconcilesRealProgram() throws {
        let database = try AppDatabase.inMemory()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        try ExerciseStore(database).save(ExerciseCatalog.seed)
        // setGoalMax below has a foreign key to a real user row, not just any UUID.
        let user = try UserStore(database, calendar: calendar).localUser()
        try ProgramImporter(database, calendar: calendar).importProgram(
            try ProgramImporter.bundledBlock1,
            for: user.id,
            startDate: calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        )

        let result = try CatalogImporter(database).importAndReconcile(try CatalogImporter.bundledCatalog)

        // Genuinely ambiguous entries with no honest single-exercise match —
        // confirmed by hand, not something a better matcher should silently
        // "fix" without a human deciding what they should map to.
        //
        // "Triceps" and "Biceps" are the two slots the program's combined
        // "Triceps + biceps" row expands into; each is its own open-choice slot
        // the lifter fills at workout time.
        let expectedUnmatched: Set<String> = [
            "Triceps (overhead ext / pushdown)",
            "Triceps",
            "Biceps",
            "Core (ab wheel / hanging leg raise)",
        ]
        #expect(Set(result.unmatchedNames) == expectedUnmatched)

        // All three are legitimately open-choice slots ("pick a triceps
        // exercise," "core work") confirmed by hand, not naming failures —
        // each should be flagged so achieved-max tracking skips them.
        let store = ExerciseStore(database)
        for name in expectedUnmatched {
            let exercise = try #require(try store.fetchAll().first { $0.name == name })
            #expect(exercise.isOpenChoice, "\(name) should be flagged open-choice")
        }
    }
}

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
        let result = try CatalogImporter(database).importCatalog(try CatalogImporter.bundledCatalog)

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
        try CatalogImporter(database).importCatalog(try CatalogImporter.bundledCatalog)

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

        try importer.importCatalog(try CatalogImporter.bundledCatalog)
        let countAfterFirst = try store.fetchAll().count
        let deadlift = try #require(try store.fetchAll().first { $0.name == "Barbell Deadlift" })

        try importer.importCatalog(try CatalogImporter.bundledCatalog)
        let countAfterSecond = try store.fetchAll().count

        #expect(countAfterFirst == countAfterSecond)
        // Same id preserved across the re-import — anything that referenced
        // this exercise (a planned set, a logged max) still points at it.
        let deadliftAgain = try #require(try store.fetch(id: deadlift.id))
        #expect(deadliftAgain.name == "Barbell Deadlift")
    }
}

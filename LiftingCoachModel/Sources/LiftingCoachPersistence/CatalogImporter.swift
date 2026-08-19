import Foundation
import LiftingCoachModel

/// Imports the vendored `yuhonas/free-exercise-db` snapshot (see
/// `Resources/FreeExerciseDB.LICENSE.txt`) as real exercise-catalog entries.
///
/// The vendored file is real product data — a properly licensed, public-domain
/// exercise database — so this is ongoing app infrastructure rather than a
/// dev-time convenience. `AppEnvironment` runs it once at first launch
/// alongside the rest of bootstrap, and `ProgramLoader` depends on it having
/// run: a program names its exercises by the slugs this imports.
///
/// It loads the catalog and stops there. It used to also run a "reconcile"
/// pass that read every exercise with no catalog link, guessed which canonical
/// entry it probably was from keyword overlap in its name, and copied that
/// entry's metadata across. That's gone: a program says which exercise it
/// means by naming the slug, so there is nothing left to infer, and a guess
/// that lands wrong is worse than no metadata at all.
public struct CatalogImporter {
    public struct Result: Sendable {
        public var importedCount: Int
    }

    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    /// The vendored catalog snapshot.
    public static var bundledCatalog: Data {
        get throws {
            guard let url = Bundle.module.url(forResource: "FreeExerciseDB", withExtension: "json") else {
                throw ImportError.missingResource
            }
            return try Data(contentsOf: url)
        }
    }

    /// Imports the vendored catalog, upserting by `sourceSlug` so re-running
    /// this is safe.
    @discardableResult
    public func importCatalog(_ data: Data) throws -> Result {
        let entries = try JSONDecoder().decode([CatalogFile.Entry].self, from: data)
        let store = ExerciseStore(database)

        var nextID = max(1000, (try store.fetchAll().map(\.id).max() ?? 0) + 1)
        var imported = 0
        for entry in entries {
            // Upsert by identity: a re-import reuses the existing row (and its
            // id, which planned/logged sets may already reference) rather than
            // creating a duplicate.
            let id = try store.fetch(sourceSlug: entry.id)?.id ?? {
                defer { nextID += 1 }
                return nextID
            }()

            try store.save(entry.asExercise(id: id))
            imported += 1
        }

        return Result(importedCount: imported)
    }

    public enum ImportError: Error {
        case missingResource
    }
}

// MARK: - JSON shape

private enum CatalogFile {
    struct Entry: Decodable {
        var id: String
        var name: String
        var force: String?
        var level: String?
        var mechanic: String?
        var equipment: String?
        var primaryMuscles: [String]
        var secondaryMuscles: [String]
        var instructions: [String]
        var category: String

        func asExercise(id: Int) -> Exercise {
            Exercise(
                id: id,
                name: name,
                muscleGroup: primaryMuscles.first?.capitalized ?? "Other",
                equipment: equipment,
                primaryMuscles: primaryMuscles.isEmpty ? nil : primaryMuscles,
                secondaryMuscles: secondaryMuscles.isEmpty ? nil : secondaryMuscles,
                instructions: instructions.isEmpty ? nil : instructions,
                level: level,
                category: category,
                mechanic: mechanic,
                force: force,
                sourceSlug: self.id
            )
        }
    }
}

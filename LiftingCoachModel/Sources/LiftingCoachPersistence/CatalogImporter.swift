import Foundation
import LiftingCoachModel

/// Imports the vendored `yuhonas/free-exercise-db` snapshot (see
/// `Resources/FreeExerciseDB.LICENSE.txt`) as real exercise-catalog entries,
/// and best-effort-enriches any exercise that doesn't already have catalog
/// metadata by matching it against the newly-imported set.
///
/// Unlike `ProgramImporter`, this **is** ongoing app infrastructure, not a
/// one-off dev tool — the vendored file is real product data (a properly
/// licensed, public-domain exercise database), not a personal spreadsheet.
/// `AppEnvironment` runs it once at first launch alongside the rest of
/// bootstrap.
public struct CatalogImporter {
    public struct Result: Sendable {
        public var importedCount: Int
        public var enrichedCount: Int
        public var unmatchedNames: [String]
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

    /// Imports the vendored catalog (upserting by `sourceSlug`, so re-running
    /// this is safe), then enriches every exercise that doesn't yet have
    /// catalog metadata by matching it against what was just imported.
    ///
    /// The two are one operation rather than two separate calls because
    /// enrichment is only meaningful once the candidates it matches against
    /// actually exist in the database.
    @discardableResult
    public func importAndReconcile(_ data: Data) throws -> Result {
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

        let (enriched, unmatched) = try reconcile(store: store)

        return Result(importedCount: imported, enrichedCount: enriched, unmatchedNames: unmatched)
    }

    /// Matches every exercise with no catalog link (`sourceSlug == nil`)
    /// against the catalog-sourced ones, and fills in metadata for whatever
    /// clears `CatalogMatcher`'s bar. See `CatalogMatcher`'s doc comment for
    /// why this is deliberately low-precision-tolerant: some names (a
    /// combined "Triceps + biceps" accessory slot, an ad-hoc "Walk with wife")
    /// have no honest match, and are left alone rather than guessed at.
    ///
    /// Never touches `name` or `id` — enrichment adds metadata to an existing
    /// exercise, it doesn't replace it with the canonical one it matched.
    private func reconcile(store: ExerciseStore) throws -> (enriched: Int, unmatched: [String]) {
        let unenriched = try store.fetchUnenriched()
        guard !unenriched.isEmpty else { return (0, []) }

        let catalogSourced = try store.fetchAll().filter { $0.sourceSlug != nil }
        let candidates = catalogSourced.compactMap { exercise in
            exercise.sourceSlug.map { CatalogMatcher.Candidate(name: exercise.name, sourceSlug: $0) }
        }
        let bySlug = Dictionary(uniqueKeysWithValues: catalogSourced.compactMap { exercise in
            exercise.sourceSlug.map { ($0, exercise) }
        })

        var enrichedCount = 0
        var unmatched: [String] = []

        for exercise in unenriched {
            guard let match = CatalogMatcher.match(exercise.name, against: candidates),
                  let canonical = bySlug[match.sourceSlug]
            else {
                unmatched.append(exercise.name)
                continue
            }

            var updated = exercise
            updated.equipment = canonical.equipment
            updated.primaryMuscles = canonical.primaryMuscles
            updated.secondaryMuscles = canonical.secondaryMuscles
            updated.instructions = canonical.instructions
            updated.level = canonical.level
            updated.category = canonical.category
            updated.mechanic = canonical.mechanic
            updated.force = canonical.force
            // matchedSlug, not sourceSlug: this row keeps its own name/id and
            // did not become that exercise — sourceSlug is an identity claim
            // and unique, which multiple program exercises matching the same
            // canonical entry would violate. See Exercise.swift.
            updated.matchedSlug = canonical.sourceSlug

            try store.save(updated)
            enrichedCount += 1
        }

        return (enrichedCount, unmatched)
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

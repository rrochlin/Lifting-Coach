import Foundation
import GRDB
import LiftingCoachModel

/// GRDB row mapping for `Exercise`. Kept separate from the domain type so the
/// model layer stays free of persistence concerns.
///
/// The array-typed catalog fields are stored JSON-encoded in text columns —
/// they're read-mostly reference data, not something filtered on in SQL today,
/// so a child table per array wasn't worth the join complexity. Same pattern
/// `workoutSet.plannedFrom` already established.
struct ExerciseRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exercise"

    var id: Int
    var name: String
    var muscleGroup: String
    var equipment: String?
    var primaryMuscles: String?
    var secondaryMuscles: String?
    var instructions: String?
    var level: String?
    var category: String?
    var mechanic: String?
    var force: String?
    var sourceSlug: String?
    var matchedSlug: String?
    var isOpenChoice: Bool

    init(_ exercise: Exercise) {
        self.id = exercise.id
        self.name = exercise.name
        self.muscleGroup = exercise.muscleGroup
        self.equipment = exercise.equipment
        self.primaryMuscles = Self.encode(exercise.primaryMuscles)
        self.secondaryMuscles = Self.encode(exercise.secondaryMuscles)
        self.instructions = Self.encode(exercise.instructions)
        self.level = exercise.level
        self.category = exercise.category
        self.mechanic = exercise.mechanic
        self.force = exercise.force
        self.sourceSlug = exercise.sourceSlug
        self.matchedSlug = exercise.matchedSlug
        self.isOpenChoice = exercise.isOpenChoice
    }

    var domain: Exercise {
        Exercise(
            id: id,
            name: name,
            muscleGroup: muscleGroup,
            equipment: equipment,
            primaryMuscles: Self.decode(primaryMuscles),
            secondaryMuscles: Self.decode(secondaryMuscles),
            instructions: Self.decode(instructions),
            level: level,
            category: category,
            mechanic: mechanic,
            force: force,
            sourceSlug: sourceSlug,
            matchedSlug: matchedSlug,
            isOpenChoice: isOpenChoice
        )
    }

    private static func encode(_ strings: [String]?) -> String? {
        guard let strings else { return nil }
        return try? String(decoding: JSONEncoder().encode(strings), as: UTF8.self)
    }

    private static func decode(_ json: String?) -> [String]? {
        guard let json else { return nil }
        return try? JSONDecoder().decode([String].self, from: Data(json.utf8))
    }
}

/// Read/write access to the exercise catalog.
///
/// This is the one fully-wired store in the phase 1 scaffold — it proves the
/// domain ↔ SQLite seam end to end. The workout, plan, and block stores follow
/// the same shape and are the next thing to build out.
public struct ExerciseStore: Sendable {
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    public func save(_ exercise: Exercise) throws {
        try database.writer.write { db in
            try ExerciseRecord(exercise).save(db)
        }
    }

    public func save(_ exercises: [Exercise]) throws {
        try database.writer.write { db in
            for exercise in exercises {
                try ExerciseRecord(exercise).save(db)
            }
        }
    }

    public func fetch(id: Int) throws -> Exercise? {
        try database.writer.read { db in
            try ExerciseRecord.fetchOne(db, key: id)?.domain
        }
    }

    /// The catalog-sourced exercise matching a given vendored-catalog identity,
    /// if it's already been imported — lets a re-import upsert by identity
    /// instead of creating a duplicate row.
    public func fetch(sourceSlug: String) throws -> Exercise? {
        try database.writer.read { db in
            try ExerciseRecord
                .filter(Column("sourceSlug") == sourceSlug)
                .fetchOne(db)?
                .domain
        }
    }

    /// Exercises with no catalog-metadata link — manually created or
    /// program-imported entries `CatalogMatcher` hasn't (yet, or ever
    /// successfully) enriched. This is exactly the set a reconciliation pass
    /// needs to consider.
    public func fetchUnenriched() throws -> [Exercise] {
        try database.writer.read { db in
            try ExerciseRecord
                .filter(Column("sourceSlug") == nil && Column("primaryMuscles") == nil)
                .order(Column("name"))
                .fetchAll(db)
                .map(\.domain)
        }
    }

    public func fetchAll() throws -> [Exercise] {
        try database.writer.read { db in
            try ExerciseRecord
                .order(Column("name"))
                .fetchAll(db)
                .map(\.domain)
        }
    }

    public func search(_ query: String) throws -> [Exercise] {
        try database.writer.read { db in
            try ExerciseRecord
                .filter(Column("name").like("%\(query)%"))
                .order(Column("name"))
                .fetchAll(db)
                .map(\.domain)
        }
    }

    /// Whether any catalog-sourced exercise has ever been imported — the guard
    /// `CatalogImporter`'s caller uses to run it only once per install rather
    /// than on every cold start.
    public func hasCatalogImport() throws -> Bool {
        try database.writer.read { db in
            try ExerciseRecord.filter(Column("sourceSlug") != nil).fetchCount(db) > 0
        }
    }

    public func delete(id: Int) throws {
        _ = try database.writer.write { db in
            try ExerciseRecord.deleteOne(db, key: id)
        }
    }
}

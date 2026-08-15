import Foundation
import GRDB
import LiftingCoachModel

/// GRDB row mapping for `Exercise`. Kept separate from the domain type so the
/// model layer stays free of persistence concerns.
struct ExerciseRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exercise"

    var id: Int
    var name: String
    var muscleGroup: String

    init(_ exercise: Exercise) {
        self.id = exercise.id
        self.name = exercise.name
        self.muscleGroup = exercise.muscleGroup
    }

    var domain: Exercise {
        Exercise(id: id, name: name, muscleGroup: muscleGroup)
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

    public func delete(id: Int) throws {
        _ = try database.writer.write { db in
            try ExerciseRecord.deleteOne(db, key: id)
        }
    }
}

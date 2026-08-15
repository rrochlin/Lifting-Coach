import Foundation
import Observation
import LiftingCoachModel
import LiftingCoachPersistence

/// Everything the views need, resolved once at launch and passed down through
/// the SwiftUI environment.
///
/// This is the composition root. Views never construct a store or a backend
/// client themselves — which is what makes the phase 2 swap (a real
/// `BackendClient` in place of `UnavailableBackend`) a one-line change here
/// rather than a hunt through the view layer.
@Observable
public final class AppEnvironment {
    public let database: AppDatabase
    public let exercises: ExerciseStore
    public let workouts: WorkoutStore

    /// The seam where the phase 2 AWS backend lands. Nothing is wired up behind
    /// it yet — see `Backend/BackendClient.swift`.
    public let backend: any BackendClient

    public init(database: AppDatabase, backend: any BackendClient) {
        self.database = database
        self.exercises = ExerciseStore(database)
        self.workouts = WorkoutStore(database)
        self.backend = backend
    }

    /// The real app: on-disk SQLite, no backend.
    public static func live() throws -> AppEnvironment {
        let database = try AppDatabase.onDisk()
        let environment = AppEnvironment(database: database, backend: UnavailableBackend())
        try environment.seedCatalogIfNeeded()
        return environment
    }

    /// In-memory database with the seed catalog, for previews and manual testing.
    public static func preview() -> AppEnvironment {
        // Previews are already a development-only path; a failure here is a bug
        // in the scaffold, not a runtime condition to handle.
        let database = try! AppDatabase.inMemory()
        let environment = AppEnvironment(database: database, backend: UnavailableBackend())
        try! environment.seedCatalogIfNeeded()
        return environment
    }

    /// Populates the placeholder exercise catalog on first launch.
    ///
    /// Temporary: `Concepts.md` calls for a real catalog with assets and
    /// equipment data. When that exists this becomes a bundled-resource import,
    /// not a hardcoded array.
    func seedCatalogIfNeeded() throws {
        guard try exercises.fetchAll().isEmpty else { return }
        try exercises.save(ExerciseCatalog.seed)
    }
}

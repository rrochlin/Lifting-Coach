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
    public let plans: PlanStore
    public let users: UserStore

    /// The single local lifter. Phase 1 has no sign-in, so this is resolved once
    /// at launch and treated as fixed for the session.
    public private(set) var currentUser: User?

    /// The seam where the phase 2 AWS backend lands. Nothing is wired up behind
    /// it yet — see `Backend/BackendClient.swift`.
    public let backend: any BackendClient

    public init(database: AppDatabase, backend: any BackendClient) {
        self.database = database
        self.exercises = ExerciseStore(database)
        self.workouts = WorkoutStore(database)
        self.plans = PlanStore(database)
        self.users = UserStore(database)
        self.backend = backend
    }

    /// The real app: on-disk SQLite, no backend.
    public static func live() throws -> AppEnvironment {
        let database = try AppDatabase.onDisk()
        let environment = AppEnvironment(database: database, backend: UnavailableBackend())
        try environment.bootstrap()
        return environment
    }

    /// In-memory database with the seed catalog, for previews and manual testing.
    public static func preview() -> AppEnvironment {
        // Previews are already a development-only path; a failure here is a bug
        // in the scaffold, not a runtime condition to handle.
        let database = try! AppDatabase.inMemory()
        let environment = AppEnvironment(database: database, backend: UnavailableBackend())
        try! environment.bootstrap()
        return environment
    }

    private func bootstrap() throws {
        currentUser = try users.localUser()
        // Catalog first, program second — the order matters now that the
        // program import resolves its exercises onto catalog entries via
        // ProgramExerciseMap. With an empty catalog there'd be nothing to
        // resolve against and every program exercise would fall back to a
        // placeholder, which is exactly the duplication the mapping removes.
        try importCatalogIfNeeded()
        try importSampleBlockIfNeeded()
        // The program import writes goal maxes — re-read once at the end.
        currentUser = try users.localUser()
    }

    /// First launch only: loads the owner's real 12-week program (Block 1) so
    /// the app opens with an actual training block instead of an empty plan.
    ///
    /// Week 1 starts on the Monday of the current week — the program's
    /// week/dayOfWeek grid is Monday-anchored.
    private func importSampleBlockIfNeeded() throws {
        guard let user = currentUser else { return }
        guard try plans.fetchPlan(userId: user.id).blocks == nil else { return }

        var calendar = Calendar.current
        calendar.firstWeekday = 2  // Monday
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()

        try ProgramImporter(database).importProgram(
            try ProgramImporter.bundledBlock1,
            for: user.id,
            startDate: thisWeek
        )
    }

    /// Re-reads the lifter after their metrics change, so a newly recorded 1RM
    /// is reflected the next time a plan resolves a `%1RM` prescription.
    public func reloadUser() {
        currentUser = try? users.localUser()
    }

    /// Deliberately no longer seeded into the app database.
    ///
    /// `ExerciseCatalog.seed`'s ten hardcoded entries were a stand-in from
    /// before a real catalog existed. Now that the vendored catalog is imported
    /// and the program resolves onto it, seeding them would put ten more
    /// non-catalog exercises in the picker and split maxes between a seed
    /// "Back Squat" and the catalog's "Barbell Squat". The type stays as a
    /// convenient fixture for tests, which construct it explicitly.
    func seedCatalogIfNeeded() throws {}

    /// First launch only: imports the vendored `free-exercise-db` catalog
    /// (~870 exercises, see `CatalogImporter`) and, in the same pass,
    /// best-effort-enriches whatever exercises don't already have catalog
    /// metadata — the seed entries and anything the program import created.
    private func importCatalogIfNeeded() throws {
        guard try !exercises.hasCatalogImport() else { return }
        try CatalogImporter(database).importAndReconcile(try CatalogImporter.bundledCatalog)
    }
}

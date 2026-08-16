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
        try seedCatalogIfNeeded()
        currentUser = try users.localUser()
        try importSampleBlockIfNeeded()
        // Runs after the program import, not before: reconciliation enriches
        // whatever exercises already exist with no catalog link, which
        // includes the ones the program import just created. Running it first
        // would mean reconciling against an empty program.
        try importCatalogIfNeeded()
        // Both imports can touch the lifter's goal maxes / catalog links —
        // re-read once at the end rather than after each.
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

    /// Seeds the big-three placeholder entries (`ExerciseCatalog.seed`, ids
    /// 1-10) that `HomeView` and `ProgramImporter` reference by id. Superseded
    /// in richness by `importCatalogIfNeeded` below, but kept as the very
    /// first thing to exist — those ids need to be stable before anything else
    /// runs, and the seed's own id range never collides with the catalog
    /// import's (which starts at 1000).
    func seedCatalogIfNeeded() throws {
        guard try exercises.fetchAll().isEmpty else { return }
        try exercises.save(ExerciseCatalog.seed)
    }

    /// First launch only: imports the vendored `free-exercise-db` catalog
    /// (~870 exercises, see `CatalogImporter`) and, in the same pass,
    /// best-effort-enriches whatever exercises don't already have catalog
    /// metadata — the seed entries and anything the program import created.
    private func importCatalogIfNeeded() throws {
        guard try !exercises.hasCatalogImport() else { return }
        try CatalogImporter(database).importAndReconcile(try CatalogImporter.bundledCatalog)
    }
}

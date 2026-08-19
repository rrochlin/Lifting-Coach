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
        // Catalog first, program second. The program names its exercises by
        // catalog slug, so with an empty catalog there'd be nothing for those
        // slugs to resolve to.
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

        try ProgramLoader(database).load(
            try ProgramLoader.bundledBlock1,
            for: user.id,
            startDate: thisWeek
        )
    }

    /// The unit weights are read and entered in, app-wide.
    ///
    /// Falls back to pounds only in the window before the lifter is resolved at
    /// launch — every real read has a user behind it.
    public var weightUnit: WeightUnit { currentUser?.preferredUnit ?? .pounds }

    /// Switches the unit every screen reads weights in.
    ///
    /// Nothing stored changes: a set logged at 225 lb is still 225 lb on disk,
    /// and simply reads as 102.06 kg from here on. Converting the tables would
    /// make a display choice destructive and would round every historical row.
    public func setWeightUnit(_ unit: WeightUnit) {
        guard let user = currentUser, user.preferredUnit != unit else { return }
        try? users.setPreferredUnit(unit, for: user.id)
        reloadUser()
    }

    /// The unit a given lift is read and entered in — its own preference, then
    /// the app-wide default. The third and most specific level, a single set's
    /// own `WorkoutSet.unit`, is applied by whoever holds the set.
    public func weightUnit(forExerciseID exerciseID: Int) -> WeightUnit {
        currentUser?.unit(forExerciseID: exerciseID) ?? .pounds
    }

    /// Pins one lift to a unit, or clears it back to the app default with `nil`.
    ///
    /// Sticky from here on, which is the point — the kg dumbbell rack is still
    /// kg next week. Nothing stored changes, same as `setWeightUnit`.
    public func setExerciseUnit(_ unit: WeightUnit?, forExerciseID exerciseID: Int) {
        guard let user = currentUser else { return }
        try? users.setUnit(unit, forExerciseID: exerciseID, for: user.id)
        reloadUser()
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
    /// (~870 exercises, see `CatalogImporter`).
    private func importCatalogIfNeeded() throws {
        guard try !exercises.hasCatalogImport() else { return }
        try CatalogImporter(database).importCatalog(try CatalogImporter.bundledCatalog)
    }
}

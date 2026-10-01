import Foundation
import Observation
import OSLog
import LiftingCoachModel
import LiftingCoachPersistence

/// Everything the views need, resolved once at launch and passed down through
/// the SwiftUI environment.
///
/// This is the composition root. Views never construct a store or a backend
/// client themselves — which is what makes the phase 2 swap (a real
/// `BackendClient` in place of `UnavailableBackend`) a one-line change here
/// rather than a hunt through the view layer.
///
/// `@MainActor` because it exists to serve views, and because its upload
/// triggers hand work to the `SnapshotSync` actor and come back to update
/// `cloud` — which is only sound if one isolation domain owns this object.
@MainActor
@Observable
public final class AppEnvironment {
    public let database: AppDatabase
    public let exercises: ExerciseStore
    public let workouts: WorkoutStore
    public let plans: PlanStore
    public let users: UserStore
    /// Assembles the whole local database into one archive file — the Profile
    /// screen's export. Built here like every other store: views never
    /// construct one.
    public let exporter: DataExporter
    /// Per-lift history, derived from the log. See `ExerciseStatsStore` for why
    /// this is a rebuilt table rather than a live query or a counter.
    public let exerciseStats: ExerciseStatsStore

    /// The single local lifter. Phase 1 has no sign-in, so this is resolved once
    /// at launch and treated as fixed for the session.
    public private(set) var currentUser: User?

    /// Cognito and S3 — see `Backend/CognitoBackend.swift`. Previews and tests
    /// get `UnavailableBackend`.
    public let backend: any BackendClient

    /// What Profile shows about the cloud copy. Refreshed after anything that
    /// could change it, rather than polled.
    public private(set) var cloud = CloudStatus()

    /// Kept so a restore staged from Profile can name the account it's for,
    /// and so the launch-time restore can write the right watermark.
    private let watermarks: any SnapshotWatermarkStore

    /// Decides when the database is worth uploading. See `SnapshotSync` — the
    /// short version is that it costs nothing until there's an account, because
    /// it checks for one before it exports anything.
    public let snapshotSync: SnapshotSync

    public init(
        database: AppDatabase,
        backend: any BackendClient,
        watermarks: any SnapshotWatermarkStore = UserDefaultsWatermarkStore()
    ) {
        self.database = database
        self.exercises = ExerciseStore(database)
        self.workouts = WorkoutStore(database)
        self.plans = PlanStore(database)
        self.users = UserStore(database)
        self.exporter = DataExporter(database)
        self.exerciseStats = ExerciseStatsStore(database)
        self.backend = backend
        self.watermarks = watermarks
        self.snapshotSync = SnapshotSync(
            database: database,
            watermarks: watermarks,
            workingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("LiftingCoach/outbox", isDirectory: true),
            // The account comes from the live session rather than from the
            // database binding: a snapshot is filed under the identity that is
            // authorised to PUT it, and an expired session can't upload however
            // firmly the `user` row says whose log this is.
            account: { await backend.currentSession?.subject },
            upload: { try await backend.uploadSnapshot($0, condition: $1) }
        )
    }

    /// The real app: on-disk SQLite, backed up to S3 once signed in.
    ///
    /// A restore staged on Profile is applied here, **before** the database is
    /// opened — the only moment its file can be swapped safely. See
    /// `PendingRestore`.
    public static func live(deviceID: String) throws -> AppEnvironment {
        let watermarks = UserDefaultsWatermarkStore()
        let restore = PendingRestore.applyIfStaged(watermarks: watermarks)
        let database = try AppDatabase.onDisk()
        let environment = AppEnvironment(
            database: database,
            backend: CognitoBackend(deviceID: deviceID),
            watermarks: watermarks
        )
        environment.cloud.launchRestore = restore
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
        // Stats are derived, so a fresh install (or one whose log arrived by
        // import rather than through the tracker) still needs them computed
        // once. Cheap when there's nothing to count.
        if let user = currentUser { try exerciseStats.rebuild(for: user.id) }
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
        snapshotDidChange(.lifterUpdated)
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
        snapshotDidChange(.lifterUpdated)
    }

    /// Re-reads the lifter after their metrics change, so a newly recorded 1RM
    /// is reflected the next time a plan resolves a `%1RM` prescription.
    public func reloadUser() {
        currentUser = try? users.localUser()
    }

    // MARK: Snapshot upload

    /// Reports that something worth uploading happened, and lets `SnapshotSync`
    /// decide whether it was.
    ///
    /// Fire and forget on purpose: nothing the lifter is doing should wait on an
    /// upload, and nothing they're doing should fail because one did. The error
    /// is swallowed here and kept on the actor as `SnapshotSync.lastFailure`,
    /// which is also the only reason these tasks capture nothing but the actor
    /// — there is no caller left to hand a failure back to.
    ///
    /// A failure needs no handling beyond that: the watermark is untouched, so
    /// the next trigger retries by the ordinary path rather than by a second
    /// mechanism written to recover from the first.
    ///
    /// Every trigger goes through these two methods rather than reaching for the
    /// actor directly, so "when do we upload" stays one rule instead of one per
    /// call site.
    public func snapshotDidChange(_ trigger: SnapshotSync.Trigger) {
        let sync = snapshotSync
        Task { @MainActor in
            await sync.markChanged()
            let outcome = try? await sync.syncIfNeeded(trigger)
            self.recordSync(outcome)
        }
    }

    /// Checks whether an upload is due without claiming anything changed.
    ///
    /// This is what backgrounding calls. It is cheap when nothing has happened
    /// — no export, no gzip — which is what makes it safe to fire on an event
    /// the app sees dozens of times a day.
    public func snapshotSyncIfNeeded(_ trigger: SnapshotSync.Trigger) {
        let sync = snapshotSync
        Task { @MainActor in
            let outcome = try? await sync.syncIfNeeded(trigger)
            self.recordSync(outcome)
        }
    }

    /// The awaitable form of the background trigger, so the caller can hold a
    /// background task open exactly as long as the upload takes.
    @MainActor
    public func syncBeforeSuspending() async {
        let outcome = try? await snapshotSync.syncIfNeeded(.enteringBackground)
        recordSync(outcome)
    }

    // MARK: Account and cloud copy

    /// Signs in, then binds this database to the account.
    ///
    /// The binding is the guard `Overview.md` and INFRA-SPEC §3.2 rely on: a
    /// database that already belongs to one account refuses a second, because
    /// adopting a log under another identity would upload one person's training
    /// into somebody else's backup. Email and Sign in with Apple are *separate*
    /// accounts in Cognito, so switching method on an existing install lands
    /// here — and is signed straight back out with the reason, rather than left
    /// half-signed-in.
    @MainActor
    public func signIn(
        using authenticate: @Sendable (URL, String) async throws -> URL
    ) async throws {
        let session = try await backend.signIn(using: authenticate)
        guard let user = currentUser else { return }
        do {
            try users.bind(cognitoSub: session.subject, to: user.id)
        } catch AccountBindingError.boundToAnotherAccount {
            await backend.signOut()
            await refreshCloud()
            throw AccountError.boundToAnotherAccount
        }
        await refreshCloud()
        // The first upload for an account is always due; this is where a
        // reinstalled phone discovers the cloud already has a backup.
        let outcome = try? await snapshotSync.syncIfNeeded(.signedIn)
        recordSync(outcome)
    }

    /// Signs out locally. The database stays bound to the account — signing
    /// back in as the same person resumes backups; anyone else is refused.
    @MainActor
    public func signOut() async {
        await backend.signOut()
        await refreshCloud()
    }

    /// Uploads now if anything changed since the last backup.
    @MainActor
    public func backUpNow() async {
        do {
            recordSync(try await snapshotSync.syncIfNeeded(.lifterUpdated))
        } catch {
            await refreshCloud()
        }
    }

    /// The lifter chose this phone's data over the cloud copy.
    @MainActor
    public func replaceCloudCopy() async {
        do {
            recordSync(try await snapshotSync.overwriteCloudCopy())
        } catch {
            await refreshCloud()
        }
    }

    /// Downloads the cloud copy and stages it to replace this phone's database
    /// at the next launch. Refuses now, with the reason, if that would delete
    /// workouts this phone has and the backup doesn't.
    @MainActor
    public func stageRestore() async throws {
        guard let account = await backend.currentSession?.subject else { throw CloudActionError.notSignedIn }
        PendingRestore.discard()
        let directory = try PendingRestore.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = try PendingRestore.archiveURL()
        let remote = try await backend.downloadSnapshot(to: archive)

        let importer = SnapshotImporter()
        let prepared = try importer.prepare(archive, into: directory, named: "check")
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let assessment = try importer.assess(prepared, against: try AppDatabase.defaultURL())
        guard assessment.isSafe else {
            PendingRestore.discard()
            throw CloudActionError.restoreWouldDiscard(assessment.localOnlyCount)
        }
        try PendingRestore(account: account, etag: remote.etag).stage()
        cloud.restoreStaged = true
    }

    /// Re-reads the session, the sync state and what the cloud holds.
    @MainActor
    public func refreshCloud() async {
        cloud.session = await backend.currentSession
        cloud.hasConflict = await snapshotSync.hasConflict
        cloud.failure = await snapshotSync.lastFailure
        cloud.restoreStaged = PendingRestore.pending() != nil
        if cloud.session != nil {
            cloud.remote = try? await backend.latestSnapshot()
        } else {
            cloud.remote = nil
        }
    }

    @MainActor
    private func recordSync(_ outcome: SnapshotSync.Outcome?) {
        if case .uploaded = outcome { cloud.lastBackup = Date() }
        Task {
            await refreshCloud()
            // Outcome and failure only — never a token, a key or a body.
            Self.log.info("sync: \(String(describing: outcome), privacy: .public) conflict=\(self.cloud.hasConflict) failure=\(self.cloud.failure ?? "none", privacy: .public)")
        }
    }

    /// `log stream --predicate 'subsystem == "com.rrochlin.LiftingCoach"'`
    private static let log = Logger(subsystem: "com.rrochlin.LiftingCoach", category: "cloud")

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

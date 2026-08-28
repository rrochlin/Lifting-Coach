import Foundation

/// Decides *when* a snapshot goes up, and makes sure the same bytes never go up
/// twice.
///
/// `SnapshotExporter` makes the file and `BackendClient` ships it; this is the
/// part in between, and it exists because the two obvious policies are both
/// wrong. Uploading on every write means gzipping a megabyte after every logged
/// set. Uploading on a timer means the one thing worth having in the cloud — the
/// session that just ended — sits on the phone for an arbitrary interval.
///
/// So: **callers say what happened, and this decides whether that's worth a
/// megabyte.** Two filters, cheap one first.
///
/// - `markChanged()` is a flag, set by the triggers that actually alter the log
///   or the plan. Backgrounding happens dozens of times a day; without the flag,
///   dozens of exports a day happen with it, all of them producing bytes that
///   are already in the bucket.
/// - The digest is the second filter, and it catches what a flag can't: a
///   workout started and discarded, a plan opened and saved untouched. Both mark
///   the app changed and both leave the database exactly as it was.
///   `SnapshotExporter` writes deterministically — no mtime in the gzip header —
///   so identical data really does produce identical bytes and the comparison is
///   exact rather than a heuristic.
///
/// Nothing here retries. A failed upload leaves the watermark alone, so the next
/// trigger finds the snapshot still un-uploaded and tries again — which is the
/// same code path as the first attempt rather than a second one written to
/// recover from it.
public actor SnapshotSync {
    /// What prompted a sync. Carried for diagnostics only — no trigger is
    /// treated differently from any other, which is what keeps "when do we
    /// upload" a single rule rather than one per call site.
    public enum Trigger: String, Sendable, Equatable {
        case workoutEnded
        case planSaved
        case historyEdited
        /// Bodyweight, a goal max, a unit preference — anything on the lifter
        /// rather than on a workout.
        case lifterUpdated
        case enteringBackground
        case signedIn
        case openingCoachChat
    }

    public enum Outcome: Sendable, Equatable {
        case uploaded(byteCount: Int, sha256: String)
        case skipped(Reason)
    }

    public enum Reason: Sendable, Equatable {
        /// No account to file it under — phase 1, or signed out. Checked before
        /// exporting, so the whole mechanism costs nothing until it's turned on.
        case noAccount
        /// Nothing has reported a change since the last upload.
        case nothingChanged
        /// Something reported a change, but the database exports to exactly the
        /// bytes already in the bucket.
        case identicalToLastUpload
    }

    private let database: AppDatabase
    private let watermarks: any SnapshotWatermarkStore
    private let workingDirectory: URL
    private let fileManager: FileManager
    /// The Cognito `sub` to file this under, or `nil` when there's nobody to
    /// upload for. One closure rather than two, because "is there a backend"
    /// and "are we signed in" have the same answer here and the same
    /// consequence.
    private let account: @Sendable () async -> String?
    private let upload: @Sendable (SnapshotExporter.Snapshot) async throws -> Void

    private var hasChanged = false

    /// Why the last sync failed, or `nil` if the last one didn't.
    ///
    /// The status lives here rather than on whoever calls this, because every
    /// trigger is fire-and-forget — there is no caller still around to be
    /// handed an error. `syncIfNeeded` still throws for anyone who wants to
    /// wait; this is for the screen that eventually asks how it's going.
    public private(set) var lastFailure: String?

    public init(
        database: AppDatabase,
        watermarks: any SnapshotWatermarkStore,
        workingDirectory: URL,
        fileManager: FileManager = .default,
        account: @escaping @Sendable () async -> String?,
        upload: @escaping @Sendable (SnapshotExporter.Snapshot) async throws -> Void
    ) {
        self.database = database
        self.watermarks = watermarks
        self.workingDirectory = workingDirectory
        self.fileManager = fileManager
        self.account = account
        self.upload = upload
    }

    /// Reports that the log or the plan changed.
    ///
    /// Cheap enough to call from anywhere and deliberately says nothing about
    /// *what* changed: this only ever uploads the whole file, so a finer-grained
    /// report would be information with nowhere to go.
    public func markChanged() {
        hasChanged = true
    }

    /// Exports and uploads if there's reason to, and says what it decided.
    ///
    /// Being an actor makes this serial for free: two triggers firing together
    /// run one after the other, and the second finds a fresh watermark and
    /// skips. There is no separate coalescing mechanism because there doesn't
    /// need to be one.
    @discardableResult
    public func syncIfNeeded(_ trigger: Trigger) async throws -> Outcome {
        guard let account = await account() else { return .skipped(.noAccount) }

        // A first upload for this account is always due, whatever the flag says
        // — signing in on a phone that already holds five years of training is
        // exactly the case where nothing has "changed" and everything needs to
        // go up. Keyed by account, so signing in as somebody else can't inherit
        // a watermark claiming their data is already in the bucket.
        let lastUploaded = watermarks.watermark(for: account)
        guard hasChanged || lastUploaded == nil else { return .skipped(.nothingChanged) }

        do {
            return try await run(account: account, lastUploaded: lastUploaded)
        } catch {
            lastFailure = error.localizedDescription
            throw error
        }
    }

    private func run(account: String, lastUploaded: String?) async throws -> Outcome {

        let snapshot = try SnapshotExporter(database).export(
            to: workingDirectory,
            named: "sync",
            fileManager: fileManager
        )
        // Gzipped, but not encrypted: it is the lifter's whole training log
        // sitting in a temp directory. It lives as long as the upload does.
        defer { try? fileManager.removeItem(at: snapshot.url) }

        guard snapshot.sha256 != lastUploaded else {
            // The database really is what the bucket already holds, so whatever
            // set the flag didn't leave a mark. Clearing it here is what stops
            // every subsequent trigger re-exporting to learn the same thing.
            hasChanged = false
            return .skipped(.identicalToLastUpload)
        }

        try await upload(snapshot)

        // Only after the upload lands. A failure leaves both the flag and the
        // watermark alone, so the next trigger retries by the ordinary path.
        watermarks.setWatermark(snapshot.sha256, for: account)
        hasChanged = false
        lastFailure = nil
        return .uploaded(byteCount: snapshot.byteCount, sha256: snapshot.sha256)
    }
}

/// Remembers the digest of the last snapshot successfully uploaded, per account.
///
/// **This must not live in the database.** The watermark describes the file, so
/// storing it inside the file would change the thing it describes: every upload
/// would dirty the database, which would produce a new digest, which would
/// warrant another upload. It is device-local bookkeeping about a remote
/// object, not part of the training log — `UserDefaults` is the right home, and
/// losing it costs one redundant upload rather than any data.
public protocol SnapshotWatermarkStore: Sendable {
    func watermark(for account: String) -> String?
    func setWatermark(_ sha256: String, for account: String)
}

/// An in-memory watermark store, for tests and previews.
public final class InMemoryWatermarkStore: SnapshotWatermarkStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func watermark(for account: String) -> String? {
        lock.withLock { storage[account] }
    }

    public func setWatermark(_ sha256: String, for account: String) {
        lock.withLock { storage[account] = sha256 }
    }
}

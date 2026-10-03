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
///
/// **Every upload is conditional** (INFRA-SPEC §8). The first one for an account
/// may only *create* the object; every later one may only replace the version
/// this device last wrote. When S3 refuses, another device uploaded — or this
/// phone was reinstalled and the cloud holds a backup it doesn't know about —
/// and sync stops and waits rather than retrying on every trigger, because the
/// answer is the lifter's to give: keep the cloud copy (restore it) or replace
/// it with this phone's (`overwriteCloudCopy()`). Detection of a lost update,
/// not mutual exclusion — and the case it catches most often on a dev phone is
/// the reinstall, where a blind upload would have replaced years of backup with
/// an empty log.
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

    /// The precondition an upload is made under. Mirrors the cloud layer's own
    /// type without depending on it, so persistence stays free of networking.
    public enum UploadCondition: Sendable, Equatable {
        /// Only if nothing exists yet.
        case firstUpload
        /// Only if the object is still the version this device last wrote.
        case unchangedSince(etag: String)
        /// Replace whatever is there. Only ever the lifter's explicit choice.
        case overwrite
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
        /// The cloud copy changed since this device last wrote it, and nothing
        /// uploads until the lifter decides what to do about that.
        case cloudCopyChanged
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
    /// Uploads under a precondition and returns the new etag. Throws
    /// `SnapshotConflict` when the precondition is refused.
    private let upload: @Sendable (SnapshotExporter.Snapshot, UploadCondition) async throws -> String

    private var hasChanged = false

    /// Set when S3 refuses a conditional write, and cleared only by a decision.
    /// In memory on purpose: a relaunch tries again, which is right, because a
    /// restore — the other way out — completes at launch.
    public private(set) var hasConflict = false

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
        upload: @escaping @Sendable (SnapshotExporter.Snapshot, UploadCondition) async throws -> String
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
        guard !hasConflict else { return .skipped(.cloudCopyChanged) }

        // A first upload for this account is always due, whatever the flag says
        // — signing in on a phone that already holds five years of training is
        // exactly the case where nothing has "changed" and everything needs to
        // go up. Keyed by account, so signing in as somebody else can't inherit
        // a watermark claiming their data is already in the bucket.
        let lastUploaded = watermarks.watermark(for: account)
        guard hasChanged || lastUploaded == nil else { return .skipped(.nothingChanged) }

        let condition: UploadCondition = watermarks.etag(for: account)
            .map { .unchangedSince(etag: $0) } ?? .firstUpload
        return try await attempt(account: account, lastUploaded: lastUploaded, condition: condition)
    }

    /// The lifter chose this phone's data over the cloud copy. Uploads
    /// unconditionally — whether or not anything changed, since the point is to
    /// replace what's there — and clears the conflict.
    @discardableResult
    public func overwriteCloudCopy() async throws -> Outcome {
        guard let account = await account() else { return .skipped(.noAccount) }
        hasConflict = false
        return try await attempt(account: account, lastUploaded: nil, condition: .overwrite)
    }

    /// The account is gone: forget everything this actor held about it.
    ///
    /// A conflict or a failure belonged to a cloud copy that no longer exists,
    /// and the watermark and etag describe an object that was deleted — left
    /// in place, a later account reusing nothing could still read them as
    /// "already uploaded". Marked changed so the next account's first upload
    /// isn't skipped as "nothing changed", though a missing watermark already
    /// makes it due.
    public func forgetAccount(_ account: String) {
        watermarks.setWatermark(nil, etag: nil, for: account)
        hasConflict = false
        lastFailure = nil
        hasChanged = true
    }

    private func attempt(account: String, lastUploaded: String?, condition: UploadCondition) async throws -> Outcome {
        do {
            return try await run(account: account, lastUploaded: lastUploaded, condition: condition)
        } catch is SnapshotConflict {
            // Not a failure: a state, and the lifter's to resolve.
            hasConflict = true
            return .skipped(.cloudCopyChanged)
        } catch {
            lastFailure = error.localizedDescription
            throw error
        }
    }

    private func run(account: String, lastUploaded: String?, condition: UploadCondition) async throws -> Outcome {

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

        let etag = try await upload(snapshot, condition)

        // Only after the upload lands. A failure leaves both the flag and the
        // watermark alone, so the next trigger retries by the ordinary path.
        watermarks.setWatermark(snapshot.sha256, etag: etag, for: account)
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
    /// The digest of the last upload, or `nil`. `nil` with an etag present is
    /// a real state: right after a restore, this device knows which cloud
    /// version it holds without having exported it itself.
    func watermark(for account: String) -> String?
    /// The etag S3 returned for this device's last write — the precondition
    /// for the next one.
    func etag(for account: String) -> String?
    func setWatermark(_ sha256: String?, etag: String?, for account: String)
}

/// Thrown by an upload whose precondition S3 refused. See `SnapshotSync`.
public struct SnapshotConflict: Error, Equatable {
    public init() {}
}

/// An in-memory watermark store, for tests and previews.
public final class InMemoryWatermarkStore: SnapshotWatermarkStore, @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [String: String] = [:]
    private var etags: [String: String] = [:]

    public init() {}

    public func watermark(for account: String) -> String? {
        lock.withLock { digests[account] }
    }

    public func etag(for account: String) -> String? {
        lock.withLock { etags[account] }
    }

    public func setWatermark(_ sha256: String?, etag: String?, for account: String) {
        lock.withLock {
            digests[account] = sha256
            etags[account] = etag
        }
    }
}

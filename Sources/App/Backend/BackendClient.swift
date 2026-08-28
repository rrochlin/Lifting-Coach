import Foundation
import LiftingCoachModel
import LiftingCoachPersistence

/// The seam where the phase 2 AWS backend lands.
///
/// The shape here follows `notes/Workout App/Backend/Overview.md`: **the phone
/// stays the system of record, the server gets a read-only copy, and it writes
/// back only proposals.** That is why there is no `push(_ workouts:)` /
/// `pullChanges(since:)` pair any more. Those were written against a row-sync
/// model, and row sync only becomes necessary with a second writer of the log —
/// which this design deliberately does not have, because only the lifter lifts.
///
/// So the surfaces are:
///
/// - **auth** — Cognito, including Sign in with Apple. It replaces the identity
///   `UserStore.localUser()` invents today, not the storage.
/// - **snapshot** — one gzipped SQLite file per user, uploaded by the phone and
///   read by nothing else. `SnapshotExporter` makes it; this ships it.
/// - **drafts** — the coach's only output. A draft is a program document in
///   `Block1.json`'s language; the lifter accepts it and `ProgramLoader` creates
///   a block *on the device*. Core Tenets §1 and §8 are this handoff.
/// - **coach** — a websocket to a Bedrock-backed Lambda.
///
/// Phase 1 ships `UnavailableBackend`. Phase 2 swaps in a real implementation at
/// `AppEnvironment.live()` and nothing in the view layer changes.
public protocol BackendClient: Sendable {
    var isAvailable: Bool { get }

    // MARK: Auth (Cognito)
    func signIn() async throws -> AuthSession
    func signOut() async throws
    var currentSession: AuthSession? { get async }

    // MARK: Snapshot (S3)

    /// Uploads the exported snapshot and returns what the server now holds.
    ///
    /// The phone writes to S3 itself, with temporary credentials from a Cognito
    /// identity pool scoped to its own `users/{sub}/` prefix — there is no
    /// service in front of the bucket to ask permission from. Nothing here can
    /// be refused for *what the file contains*: the server records the schema
    /// version by opening the object, so a snapshot from a newer build is
    /// stored and flagged rather than rejected, and a backup is never lost to a
    /// Lambda that hasn't been redeployed yet.
    @discardableResult
    func uploadSnapshot(_ snapshot: SnapshotExporter.Snapshot) async throws -> SnapshotDescriptor

    /// What the server holds, without downloading it. `nil` on an account that
    /// has never uploaded.
    func latestSnapshot() async throws -> SnapshotDescriptor?

    /// Downloads the stored snapshot to `destination`, gzipped as uploaded.
    ///
    /// This only fetches the file. Deciding whether it may replace what's on the
    /// device is `SnapshotImporter`'s job and stays on the device, because that
    /// decision is the one place phase 2 can destroy a training log.
    @discardableResult
    func downloadSnapshot(to destination: URL) async throws -> SnapshotDescriptor

    // MARK: Coach drafts (DynamoDB)

    /// Program drafts the coach has proposed and the lifter hasn't answered.
    func fetchDrafts() async throws -> [CoachDraft]

    /// Records what the lifter decided, so a draft stops being offered.
    ///
    /// The accept itself already happened locally — `ProgramLoader` created the
    /// block. This is bookkeeping, and it is the only write the coach's side of
    /// the system ever sees.
    func resolveDraft(_ id: String, as resolution: DraftResolution) async throws

    // MARK: Coach (Bedrock over websocket)
    /// Streams coach replies. Phase 2.2 — see `Features/Coach Conversation.md`.
    func coachReplies(to message: String) -> AsyncThrowingStream<String, any Error>
}

/// A signed-in lifter.
///
/// `subject` is the Cognito `sub` and is the key everything server-side is
/// filed under — the S3 prefix and every DynamoDB item. It's a string, which is
/// what makes `Overview.md`'s old question about binary-UUID key types moot.
/// `userId` stays the local `User.id`, because Cognito replaces the identity,
/// not the storage.
public struct AuthSession: Codable, Hashable, Sendable {
    public var userId: UUID
    public var subject: String
    public var email: String
    public var expiresAt: Date

    public init(userId: UUID, subject: String, email: String, expiresAt: Date) {
        self.userId = userId
        self.subject = subject
        self.email = email
        self.expiresAt = expiresAt
    }
}

/// What the server holds for one user, without the file itself.
///
/// This is `snapshotMeta` in DynamoDB. `rowCounts` is here for the same reason
/// it's on the export: it makes "the upload succeeded but the file is wrong" a
/// state something can actually notice.
public struct SnapshotDescriptor: Codable, Hashable, Sendable {
    public var etag: String
    public var schemaVersion: String
    public var byteCount: Int
    public var uploadedAt: Date
    public var rowCounts: [String: Int]

    public init(
        etag: String,
        schemaVersion: String,
        byteCount: Int,
        uploadedAt: Date,
        rowCounts: [String: Int]
    ) {
        self.etag = etag
        self.schemaVersion = schemaVersion
        self.byteCount = byteCount
        self.uploadedAt = uploadedAt
        self.rowCounts = rowCounts
    }
}

/// A program the coach is proposing.
///
/// `program` is `Block1.json`-shaped bytes, and that is the entire vocabulary
/// the coach gets. It can describe a block to create; there is no way to spell
/// a change to a logged set in it, which is what makes Core Tenet §8 a property
/// of the shape rather than a rule every Lambda has to remember.
public struct CoachDraft: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    /// The coach's own one-line account of what it changed and why, for the
    /// accept screen. Prose, not something anything parses.
    public var summary: String
    public var program: Data

    public init(id: String, createdAt: Date, summary: String, program: Data) {
        self.id = id
        self.createdAt = createdAt
        self.summary = summary
        self.program = program
    }
}

public enum DraftResolution: String, Codable, Hashable, Sendable {
    case accepted
    case declined
}

public enum BackendError: LocalizedError, Equatable {
    /// Phase 1: there is no backend. Not a failure to retry or report as an
    /// outage — the feature genuinely does not exist yet.
    case notImplementedUntilPhase2

    public var errorDescription: String? {
        switch self {
        case .notImplementedUntilPhase2:
            return "This feature needs the server backend, which isn't built yet."
        }
    }
}

/// The phase 1 backend: none.
///
/// Every call fails loudly rather than silently no-op'ing, so a view that
/// accidentally depends on the server fails in development instead of appearing
/// to work with empty data.
public struct UnavailableBackend: BackendClient {
    public init() {}

    public var isAvailable: Bool { false }

    public func signIn() async throws -> AuthSession {
        throw BackendError.notImplementedUntilPhase2
    }

    public func signOut() async throws {
        throw BackendError.notImplementedUntilPhase2
    }

    public var currentSession: AuthSession? {
        get async { nil }
    }

    @discardableResult
    public func uploadSnapshot(
        _ snapshot: SnapshotExporter.Snapshot
    ) async throws -> SnapshotDescriptor {
        throw BackendError.notImplementedUntilPhase2
    }

    public func latestSnapshot() async throws -> SnapshotDescriptor? {
        throw BackendError.notImplementedUntilPhase2
    }

    @discardableResult
    public func downloadSnapshot(to destination: URL) async throws -> SnapshotDescriptor {
        throw BackendError.notImplementedUntilPhase2
    }

    public func fetchDrafts() async throws -> [CoachDraft] {
        throw BackendError.notImplementedUntilPhase2
    }

    public func resolveDraft(_ id: String, as resolution: DraftResolution) async throws {
        throw BackendError.notImplementedUntilPhase2
    }

    public func coachReplies(to message: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: BackendError.notImplementedUntilPhase2) }
    }
}

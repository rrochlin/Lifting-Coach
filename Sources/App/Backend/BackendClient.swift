import Foundation
import LiftingCoachCloud
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
/// `CognitoBackend` is the real one. `UnavailableBackend` is the preview and
/// test double, and throws rather than quietly returning nothing.
public protocol BackendClient: Sendable {
    var isAvailable: Bool { get }

    // MARK: Auth (Cognito)

    /// Signs in with a native Sign in with Apple credential — INFRA-SPEC §3.5.
    ///
    /// The view runs Apple's sheet (`AppleSignInButton`) and hands over what it
    /// returned, so the backend never needs a window to present from and a
    /// test can pass a canned credential.
    func signIn(with apple: AppleCredential) async throws -> AuthSession

    func signOut() async

    /// Who is signed in, without touching the network. Present for as long as
    /// a refresh token is held — an hour-old id token is renewed when it's
    /// next needed, not treated as being signed out.
    var currentSession: AuthSession? { get async }

    /// Deletes the account and everything the cloud holds for it, then signs
    /// out. Returns the `sub` that was deleted.
    ///
    /// `apple` is a **fresh** confirmation from Apple's sheet, taken right
    /// after the lifter confirmed. It does three jobs: it's the conventional
    /// re-confirmation for an act that can't be undone, it signs in again so
    /// the access token is fresh, and its authorization code is what the
    /// server needs to revoke the app's Apple grant (Apple requires it).
    /// Throws `AccountDeletionError.differentAccount` if it names somebody
    /// other than who is signed in now. Uploads are refused from the moment
    /// this starts, so nothing can recreate the snapshot behind it.
    func deleteAccount(confirmedWith apple: AppleCredential) async throws -> String

    // MARK: Snapshot (S3)

    /// Uploads under a precondition and returns the etag S3 assigned.
    ///
    /// The phone writes to S3 itself, with temporary credentials from a Cognito
    /// identity pool scoped to its own `users/{sub}/` prefix — there is no
    /// service in front of the bucket. A refused precondition throws
    /// `SnapshotConflict`, which `SnapshotSync` turns into a question for the
    /// lifter. Nothing here can be refused for *what the file contains*: the
    /// server records the schema version by opening the object.
    func uploadSnapshot(
        _ snapshot: SnapshotExporter.Snapshot,
        condition: SnapshotSync.UploadCondition
    ) async throws -> String

    /// What the cloud holds, from a HEAD. `nil` on an account that has never
    /// uploaded. The phone has no DynamoDB access by design (INFRA-SPEC §6),
    /// so this is the object's own metadata, not the server's index.
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
/// `subject` is the Cognito user pool `sub` and is the key everything
/// server-side is filed under — the S3 prefix and every DynamoDB item. It is
/// *not* the identity pool's identity id, which is a different value and the
/// one mistake that would 403 every upload.
public struct AuthSession: Codable, Hashable, Sendable {
    public var subject: String
    /// May be an Apple private-relay address. Nothing keys on it.
    public var email: String?

    public init(subject: String, email: String?) {
        self.subject = subject
        self.email = email
    }
}

/// What the cloud holds for one user, from the object itself.
///
/// Deliberately thinner than the server's `snapshotMeta`: the phone reads the
/// object's own metadata with a HEAD, because it holds no DynamoDB permission —
/// the index is the server's to read, and the coach's (2.2), not the device's.
public struct SnapshotDescriptor: Codable, Hashable, Sendable {
    public var etag: String
    public var byteCount: Int
    public var uploadedAt: Date?

    public init(etag: String, byteCount: Int, uploadedAt: Date?) {
        self.etag = etag
        self.byteCount = byteCount
        self.uploadedAt = uploadedAt
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

    public func signIn(with apple: AppleCredential) async throws -> AuthSession {
        throw BackendError.notImplementedUntilPhase2
    }

    public func signOut() async {}

    public var currentSession: AuthSession? {
        get async { nil }
    }

    public func deleteAccount(confirmedWith apple: AppleCredential) async throws -> String {
        throw BackendError.notImplementedUntilPhase2
    }

    public func uploadSnapshot(
        _ snapshot: SnapshotExporter.Snapshot,
        condition: SnapshotSync.UploadCondition
    ) async throws -> String {
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

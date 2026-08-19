import Foundation
import LiftingCoachModel

/// The seam where the phase 2 AWS backend will land.
///
/// Per `Roadmap.md`, phase 1 builds clear stubs for where backend communication
/// eventually goes — accepting input at those seams now, with nothing wired up
/// behind them. The three surfaces from `Backend/Overview.md`:
///
/// - **auth** — Cognito, including Sign in with Apple
/// - **sync** — DynamoDB as the system of record for synced data
/// - **coach** — a websocket to a Bedrock-backed Lambda
///
/// Phase 1 ships `UnavailableBackend`. Phase 2 swaps in a real implementation at
/// `AppEnvironment.live()` and nothing in the view layer changes.
public protocol BackendClient: Sendable {
    var isAvailable: Bool { get }

    // MARK: Auth (Cognito)
    func signIn() async throws -> AuthSession
    func signOut() async throws
    var currentSession: AuthSession? { get async }

    // MARK: Sync (DynamoDB)
    /// Pushes local changes up. Local SQLite stays the system of record on-device;
    /// this is backup/sync, never a read dependency for the tracking loop.
    func push(_ workouts: [Workout]) async throws
    func pullChanges(since: Date?) async throws -> [Workout]

    // MARK: Coach (Bedrock over websocket)
    /// Streams coach replies. Phase 2 — see `Features/Coach Conversation.md`.
    func coachReplies(to message: String) -> AsyncThrowingStream<String, any Error>
}

public struct AuthSession: Codable, Hashable, Sendable {
    public var userId: UUID
    public var email: String
    public var expiresAt: Date

    public init(userId: UUID, email: String, expiresAt: Date) {
        self.userId = userId
        self.email = email
        self.expiresAt = expiresAt
    }
}

public enum BackendError: LocalizedError {
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

    public func push(_ workouts: [Workout]) async throws {
        throw BackendError.notImplementedUntilPhase2
    }

    public func pullChanges(since: Date?) async throws -> [Workout] {
        throw BackendError.notImplementedUntilPhase2
    }

    public func coachReplies(to message: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: BackendError.notImplementedUntilPhase2) }
    }
}

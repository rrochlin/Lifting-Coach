import Foundation
import LiftingCoachCloud
import LiftingCoachPersistence

/// The phase 2 backend: Cognito for identity, S3 for the snapshot.
///
/// Composes the four pieces in `LiftingCoachCloud` — Hosted UI sign-in, token
/// refresh, identity-pool credentials, signed S3 requests — and owns the state
/// between them: the tokens (Keychain) and the current AWS credentials
/// (memory only; they last an hour and are cheap to re-mint).
///
/// An actor because uploads fire from background triggers while the lifter may
/// be signing in or out on Profile, and a token refresh racing a sign-out must
/// not write the old tokens back.
actor CognitoBackend: BackendClient {
    private let hostedUI: HostedUI
    private let identityPool: IdentityPool
    private let bucket: SnapshotBucket
    private let tokenStore: TokenStore
    private let deviceID: String

    private var tokens: CognitoTokens?
    private var credentials: AWSCredentials?

    init(config: CloudConfig = .production, deviceID: String, tokenStore: TokenStore = TokenStore()) {
        hostedUI = HostedUI(config: config)
        identityPool = IdentityPool(config: config)
        bucket = SnapshotBucket(config: config)
        self.tokenStore = tokenStore
        self.deviceID = deviceID
        tokens = tokenStore.load()
    }

    nonisolated var isAvailable: Bool { true }

    // MARK: Auth

    func signIn(
        using authenticate: @Sendable (URL, String) async throws -> URL
    ) async throws -> AuthSession {
        let attempt = HostedUI.Attempt()
        let callback = try await authenticate(
            hostedUI.authorizeURL(for: attempt), hostedUI.config.callbackScheme
        )
        let code = try hostedUI.code(from: callback, for: attempt)
        let signedIn = try await hostedUI.exchange(code: code, for: attempt)
        let claims = try IDTokenClaims(jwt: signedIn.idToken)
        tokens = signedIn
        credentials = nil
        tokenStore.save(signedIn)
        return AuthSession(subject: claims.subject, email: claims.email)
    }

    /// Local only. The Hosted UI session was ephemeral, so there's no browser
    /// cookie to clear, and the refresh token simply stops being held — the
    /// next sign-in is a fresh one.
    func signOut() async {
        tokens = nil
        credentials = nil
        tokenStore.clear()
    }

    var currentSession: AuthSession? {
        guard let tokens, let claims = try? IDTokenClaims(jwt: tokens.idToken) else { return nil }
        return AuthSession(subject: claims.subject, email: claims.email)
    }

    // MARK: Snapshot

    func uploadSnapshot(
        _ snapshot: SnapshotExporter.Snapshot,
        condition: SnapshotSync.UploadCondition
    ) async throws -> String {
        let (subject, credentials) = try await authorised()
        let body = try Data(contentsOf: snapshot.url)
        let precondition: WritePrecondition = switch condition {
        case .firstUpload: .noExistingObject
        case .unchangedSince(let etag): .unchangedSince(etag: etag)
        case .overwrite: .overwrite
        }
        do {
            return try await bucket.put(
                body, subject: subject, precondition: precondition,
                deviceID: deviceID, credentials: credentials
            )
        } catch CloudError.cloudCopyChanged {
            throw SnapshotConflict()
        }
    }

    func latestSnapshot() async throws -> SnapshotDescriptor? {
        let (subject, credentials) = try await authorised()
        return try await bucket.head(subject: subject, credentials: credentials).map(Self.descriptor)
    }

    @discardableResult
    func downloadSnapshot(to destination: URL) async throws -> SnapshotDescriptor {
        let (subject, credentials) = try await authorised()
        let (data, remote) = try await bucket.get(subject: subject, credentials: credentials)
        try data.write(to: destination, options: .atomic)
        return Self.descriptor(remote)
    }

    // MARK: Coach — phase 2.2

    nonisolated func fetchDrafts() async throws -> [CoachDraft] {
        throw BackendError.notImplementedUntilPhase2
    }

    nonisolated func resolveDraft(_ id: String, as resolution: DraftResolution) async throws {
        throw BackendError.notImplementedUntilPhase2
    }

    nonisolated func coachReplies(to message: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: BackendError.notImplementedUntilPhase2) }
    }

    // MARK: Credentials

    /// The subject and a usable set of AWS credentials, renewing whichever has
    /// lapsed. A refresh token that has itself expired signs the lifter out —
    /// monthly, by design (INFRA-SPEC D3) — and the error says to sign in again.
    private func authorised() async throws -> (String, AWSCredentials) {
        guard var current = tokens else { throw CloudError.notSignedIn }

        // Five minutes of margin: an upload of a megabyte over cellular can
        // outlast a token that was valid when it started.
        let margin: TimeInterval = 300
        if current.expiresAt.timeIntervalSinceNow < margin {
            guard let refreshToken = current.refreshToken else { throw CloudError.signInExpired }
            do {
                current = try await hostedUI.refresh(refreshToken)
            } catch CloudError.signInExpired {
                await signOut()
                throw CloudError.signInExpired
            }
            // Re-check: a sign-out while the refresh was in flight wins.
            guard tokens != nil else { throw CloudError.notSignedIn }
            tokens = current
            credentials = nil
            tokenStore.save(current)
        }

        let subject = try IDTokenClaims(jwt: current.idToken).subject
        if let credentials, credentials.expiration.timeIntervalSinceNow > margin {
            return (subject, credentials)
        }
        let fresh = try await identityPool.credentials(idToken: current.idToken)
        credentials = fresh
        return (subject, fresh)
    }

    private static func descriptor(_ remote: RemoteSnapshot) -> SnapshotDescriptor {
        SnapshotDescriptor(etag: remote.etag, byteCount: remote.byteCount, uploadedAt: remote.lastModified)
    }
}

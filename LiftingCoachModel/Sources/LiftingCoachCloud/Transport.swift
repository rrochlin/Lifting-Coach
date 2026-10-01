import Foundation

/// The one place a request leaves the process. A protocol so tests can answer
/// with canned responses and inspect exactly what would have been sent — the
/// same narrow-seam approach as `server/`'s `SnapshotObjects`, and for the same
/// reason: the policy is what wants testing, not URLSession.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.notHTTP }
        return (data, http)
    }
}

public enum CloudError: Error, Equatable, LocalizedError {
    case notHTTP
    case malformedToken
    case signInRejected(String)
    case signInStateMismatch
    /// The refresh token has lapsed — thirty days after sign-in, by design.
    case signInExpired
    case notSignedIn
    /// **The single-writer signal.** S3 refused a conditional write because the
    /// object changed since this device last saw it: another device uploaded,
    /// or this one was reinstalled and the cloud copy predates it. Not an error
    /// to retry — a decision for the lifter (INFRA-SPEC §8).
    case cloudCopyChanged
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notHTTP: "The server's reply wasn't HTTP."
        case .malformedToken: "The sign-in token couldn't be read."
        case .signInRejected(let reason): "Sign-in didn't complete: \(reason)"
        case .signInStateMismatch: "That sign-in reply wasn't for this attempt."
        case .signInExpired: "Your sign-in has expired. Sign in again to resume backups."
        case .notSignedIn: "Not signed in."
        case .cloudCopyChanged: "The cloud backup changed since this phone last uploaded."
        case .http(let status, let body): "The server answered \(status). \(body.prefix(200))"
        }
    }
}

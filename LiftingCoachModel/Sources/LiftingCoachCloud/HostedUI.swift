import CryptoKit
import Foundation

/// The tokens a sign-in produces.
public struct CognitoTokens: Codable, Sendable, Equatable {
    public var idToken: String
    public var accessToken: String
    /// Absent on a refresh: Cognito's refresh tokens don't slide, so
    /// `REFRESH_TOKEN_AUTH` returns new id and access tokens and leaves the
    /// refresh token as it was. Thirty days from *sign-in* — INFRA-SPEC D3.
    public var refreshToken: String?
    public var expiresAt: Date

    public init(idToken: String, accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// What the app reads out of an id token.
///
/// Read without verifying the signature, and that's correct here rather than a
/// shortcut: the token came straight from Cognito over TLS in response to a
/// request this app made, and nothing on the phone *grants* anything on the
/// strength of these claims. The identity pool verifies the token properly
/// before it issues a single credential, and that's where trust lives.
public struct IDTokenClaims: Sendable, Equatable {
    public var subject: String
    public var email: String?
    public var expiresAt: Date

    public init(jwt: String) throws {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { throw CloudError.malformedToken }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard
            let data = Data(base64Encoded: payload),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sub = object["sub"] as? String,
            let exp = object["exp"] as? Double
        else { throw CloudError.malformedToken }
        subject = sub
        email = object["email"] as? String
        expiresAt = Date(timeIntervalSince1970: exp)
    }
}

/// The OAuth half of sign-in: building the Hosted UI URL, and trading the code
/// it returns for tokens.
///
/// **PKCE, always.** The client is public — a native app can't keep a secret —
/// so without a code verifier, anything that intercepts the redirect can
/// redeem the code. The verifier never leaves the device; only its hash goes
/// into the URL the browser sees.
public struct HostedUI: Sendable {
    public let config: CloudConfig
    let transport: HTTPTransport

    public init(config: CloudConfig = .production, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    /// One sign-in attempt's secrets. `state` ties the redirect to this
    /// attempt, so a stray `liftcoach://callback` can't complete it.
    public struct Attempt: Sendable, Equatable {
        public let verifier: String
        public let state: String

        public init(verifier: String = Self.random(), state: String = Self.random()) {
            self.verifier = verifier
            self.state = state
        }

        public var challenge: String {
            Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        public static func random() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return base64URL(Data(bytes))
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    /// No `identity_provider` parameter, deliberately: the Hosted UI then
    /// offers both email and Sign in with Apple, and the lifter picks.
    public func authorizeURL(for attempt: Attempt) -> URL {
        var components = URLComponents(
            url: config.authDomain.appendingPathComponent("oauth2/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "code_challenge", value: attempt.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// Pulls the code out of the redirect, refusing one that isn't for this
    /// attempt or that carries an error instead.
    public func code(from callback: URL, for attempt: Attempt) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw CloudError.signInRejected(value("error_description") ?? error)
        }
        guard value("state") == attempt.state else { throw CloudError.signInStateMismatch }
        guard let code = value("code") else { throw CloudError.signInRejected("no code returned") }
        return code
    }

    public func exchange(code: String, for attempt: Attempt) async throws -> CognitoTokens {
        try await token([
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": attempt.verifier,
        ])
    }

    /// New id and access tokens. Throws `CloudError.signInExpired` once the
    /// refresh token has lapsed, which is the app's cue to ask the lifter to
    /// sign in again — expected monthly, by design (D3).
    public func refresh(_ refreshToken: String) async throws -> CognitoTokens {
        do {
            var tokens = try await token([
                "grant_type": "refresh_token",
                "client_id": config.clientID,
                "refresh_token": refreshToken,
            ])
            tokens.refreshToken = tokens.refreshToken ?? refreshToken
            return tokens
        } catch CloudError.http(let status, _) where status == 400 {
            throw CloudError.signInExpired
        }
    }

    private func token(_ form: [String: String]) async throws -> CognitoTokens {
        var request = URLRequest(url: config.authDomain.appendingPathComponent("oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            form.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(SigV4.uriEncode($0.value))" }
                .joined(separator: "&").utf8
        )
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw CloudError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        struct Body: Decodable {
            let id_token: String
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return CognitoTokens(
            idToken: body.id_token,
            accessToken: body.access_token,
            refreshToken: body.refresh_token,
            expiresAt: Date().addingTimeInterval(body.expires_in)
        )
    }
}

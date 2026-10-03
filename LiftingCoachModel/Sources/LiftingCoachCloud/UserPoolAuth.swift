import CryptoKit
import Foundation

/// What a native Sign in with Apple hands the app.
///
/// `identityToken` is the Apple-signed JWT the server verifies;
/// `authorizationCode` is the one-time code (five minutes) that account
/// deletion needs to revoke the app's grant; `rawNonce` is the preimage of the
/// nonce the request asked Apple to embed — see `AppleNonce`.
public struct AppleCredential: Sendable, Equatable {
    public var identityToken: String
    public var authorizationCode: String
    public var rawNonce: String

    public init(identityToken: String, authorizationCode: String, rawNonce: String) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.rawNonce = rawNonce
    }

    /// Apple's `sub` and `email`, read without verifying — only to choose the
    /// username and the address to show. The server verifies the token before
    /// anything is granted on it.
    public func claims() throws -> (subject: String, email: String?) {
        let payload = try JWTPayload.decode(identityToken)
        guard let subject = payload["sub"] as? String, !subject.isEmpty else {
            throw CloudError.malformedToken
        }
        return (subject, payload["email"] as? String)
    }
}

/// One sign-in attempt's nonce. Apple embeds `hashed` in the identity token;
/// the server is sent `raw` and checks the two agree, so a token lifted from
/// some other sign-in carries a nonce nobody can produce the preimage of.
public struct AppleNonce: Sendable, Equatable {
    public let raw: String

    public init(raw: String = AppleNonce.random()) {
        self.raw = raw
    }

    /// What goes in `ASAuthorizationAppleIDRequest.nonce`: lowercase hex
    /// SHA-256, which is what Apple puts back and what the server recomputes.
    public var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Signs in to the user pool with a native Apple credential — INFRA-SPEC §3.5.
///
/// Three unsigned calls against the public client, the same JSON 1.1 shape as
/// `IdentityPool`: `SignUp` (an existing account answers
/// `UsernameExistsException`, which is the normal case), then `InitiateAuth`
/// `CUSTOM_AUTH`, then `RespondToAuthChallenge` with Apple's identity token as
/// the answer. The pool's triggers verify the token; this code only carries it.
/// What comes back is ordinary user pool tokens, so everything downstream —
/// identity pool, principal tag, S3 prefix — is unchanged from the Hosted UI.
public struct UserPoolAuth: Sendable {
    /// Every username's domain, and the one string the phone and the server
    /// must agree on — `apple.USERNAME_DOMAIN` in `server/`, pinned by a test
    /// that reads this line. `.invalid` is reserved (RFC 2606).
    public static let usernameDomain = "apple.lift-coach.invalid"

    /// The account an Apple ID signs in as. **Derived from Apple's `sub`, not
    /// the lifter's email**: an Apple ID's address can change, and an account
    /// keyed on it would change owner with it.
    public static func username(forAppleSubject subject: String) -> String {
        "\(subject.lowercased())@\(usernameDomain)"
    }

    public let config: CloudConfig
    let transport: HTTPTransport

    public init(config: CloudConfig = .production, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public func signIn(_ apple: AppleCredential) async throws -> CognitoTokens {
        let (subject, email) = try apple.claims()
        let username = Self.username(forAppleSubject: subject)

        do {
            _ = try await call("SignUp", [
                "ClientId": config.clientID,
                "Username": username,
                // Never used and never kept. The pool requires one; the client
                // has no password flow, so it can't be signed in with.
                "Password": Self.throwawayPassword(),
                "UserAttributes": [["Name": "email", "Value": username]],
                "ClientMetadata": [
                    "appleIdentityToken": apple.identityToken,
                    "appleNonce": apple.rawNonce,
                ],
            ])
        } catch CognitoIdentityProviderError.service(let type, _) where type == "UsernameExistsException" {
            // Signed in before. Expected on every sign-in but the first.
        }

        let challenge = try await call("InitiateAuth", [
            "ClientId": config.clientID,
            "AuthFlow": "CUSTOM_AUTH",
            "AuthParameters": ["USERNAME": username],
        ])
        guard let session = challenge["Session"] as? String else {
            throw CloudError.signInRejected("Cognito issued no challenge")
        }
        let answered = try await call("RespondToAuthChallenge", [
            "ClientId": config.clientID,
            "ChallengeName": "CUSTOM_CHALLENGE",
            "Session": session,
            "ChallengeResponses": ["USERNAME": username, "ANSWER": apple.identityToken],
            "ClientMetadata": ["appleNonce": apple.rawNonce],
        ])
        var tokens = try Self.tokens(from: answered)
        tokens.displayEmail = email
        return tokens
    }

    /// New id and access tokens. Throws `CloudError.signInExpired` once the
    /// refresh token has lapsed — expected monthly, by design (D3).
    public func refresh(_ refreshToken: String) async throws -> CognitoTokens {
        do {
            let reply = try await call("InitiateAuth", [
                "ClientId": config.clientID,
                "AuthFlow": "REFRESH_TOKEN_AUTH",
                "AuthParameters": ["REFRESH_TOKEN": refreshToken],
            ])
            var tokens = try Self.tokens(from: reply)
            // Cognito doesn't rotate refresh tokens; dropping it here would
            // sign the lifter out on the first refresh.
            tokens.refreshToken = tokens.refreshToken ?? refreshToken
            return tokens
        } catch CognitoIdentityProviderError.service(let type, _) where type == "NotAuthorizedException" {
            throw CloudError.signInExpired
        }
    }

    // MARK: Plumbing

    static func throwawayPassword() -> String {
        // Satisfies the pool's policy (upper, lower, digit, 8+) whatever the
        // random part happens to contain.
        "Aa1-" + AppleNonce.random()
    }

    private static func tokens(from reply: [String: Any]) throws -> CognitoTokens {
        guard
            let result = reply["AuthenticationResult"] as? [String: Any],
            let id = result["IdToken"] as? String,
            let access = result["AccessToken"] as? String
        else { throw CloudError.signInRejected("Cognito returned no tokens") }
        let lifetime = (result["ExpiresIn"] as? Double) ?? 3600
        return CognitoTokens(
            idToken: id, accessToken: access,
            refreshToken: result["RefreshToken"] as? String,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
    }

    private func call(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://cognito-idp.\(config.region).amazonaws.com/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.\(action)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.send(request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard response.statusCode == 200 else {
            // `__type` is sometimes namespaced (`…#NotAuthorizedException`).
            let type = (object["__type"] as? String)?.split(separator: "#").last.map(String.init) ?? ""
            let message = (object["message"] as? String) ?? (object["Message"] as? String) ?? ""
            if type.isEmpty {
                throw CloudError.http(response.statusCode, String(decoding: data, as: UTF8.self))
            }
            throw CognitoIdentityProviderError.service(type, message)
        }
        return object
    }
}

/// A Cognito user pool API refusal, by its error type. Mapped to `CloudError`
/// at the edge of `signIn`/`refresh`, except for the one type sign-in treats
/// as normal.
public enum CognitoIdentityProviderError: Error, Equatable, LocalizedError {
    case service(String, String)

    public var errorDescription: String? {
        switch self {
        case .service(let type, let message):
            switch type {
            // A trigger refused: the message is ours, from `auth_triggers`.
            case "UserLambdaValidationException": "Sign in with Apple couldn't be verified. \(message)"
            case "NotAuthorizedException": "Sign in with Apple couldn't be verified. Try again."
            default: "Sign-in failed (\(type)). \(message)"
            }
        }
    }
}

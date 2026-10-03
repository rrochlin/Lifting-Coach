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
    /// The address the lifter recognises, from Apple's token — possibly a
    /// private-relay forwarder. **Kept on the phone only**: the Cognito
    /// username is derived from Apple's `sub` (`UserPoolAuth`), so the id
    /// token's `email` claim is that synthetic address, not this one.
    public var displayEmail: String?

    public init(
        idToken: String, accessToken: String, refreshToken: String?, expiresAt: Date,
        displayEmail: String? = nil
    ) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.displayEmail = displayEmail
    }
}

/// A JWT's payload, unverified. See each caller for why that's sound there.
enum JWTPayload {
    static func decode(_ jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw CloudError.malformedToken }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CloudError.malformedToken }
        return object
    }
}

/// What the app reads out of a Cognito id token.
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
        let object = try JWTPayload.decode(jwt)
        guard let sub = object["sub"] as? String, let exp = object["exp"] as? Double else {
            throw CloudError.malformedToken
        }
        subject = sub
        email = object["email"] as? String
        expiresAt = Date(timeIntervalSince1970: exp)
    }
}


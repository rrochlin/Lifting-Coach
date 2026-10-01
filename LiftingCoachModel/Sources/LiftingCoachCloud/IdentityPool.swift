import Foundation

/// Trades an id token for temporary AWS credentials.
///
/// Two calls, both unsigned — the id token *is* the authentication:
/// `GetId` names this person's identity in the pool, and
/// `GetCredentialsForIdentity` returns credentials for the authenticated role.
/// The role is scoped by a principal tag carrying the user pool `sub` to
/// exactly `users/${sub}/*` — verified against the live account for both email
/// and Sign in with Apple users (INFRA-SPEC §12).
///
/// Note the two identifiers involved and which one matters: `GetId` returns the
/// identity pool's own id (`us-west-2:…`), and the S3 prefix is **not** that —
/// it's the user pool `sub` from the token. Using the wrong one produces a 403
/// on every upload.
public struct IdentityPool: Sendable {
    public let config: CloudConfig
    let transport: HTTPTransport

    public init(config: CloudConfig = .production, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public func credentials(idToken: String) async throws -> AWSCredentials {
        let logins = [config.issuer: idToken]
        let identity: [String: Any] = try await call("GetId", [
            "IdentityPoolId": config.identityPoolID,
            "Logins": logins,
        ])
        guard let identityID = identity["IdentityId"] as? String else {
            throw CloudError.http(200, "GetId returned no IdentityId")
        }
        let response: [String: Any] = try await call("GetCredentialsForIdentity", [
            "IdentityId": identityID,
            "Logins": logins,
        ])
        guard
            let creds = response["Credentials"] as? [String: Any],
            let key = creds["AccessKeyId"] as? String,
            let secret = creds["SecretKey"] as? String,
            let token = creds["SessionToken"] as? String,
            let expiration = creds["Expiration"] as? Double
        else { throw CloudError.http(200, "GetCredentialsForIdentity returned no credentials") }
        return AWSCredentials(
            accessKeyID: key, secretAccessKey: secret, sessionToken: token,
            expiration: Date(timeIntervalSince1970: expiration)
        )
    }

    private func call(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://cognito-identity.\(config.region).amazonaws.com/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityService.\(action)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw CloudError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

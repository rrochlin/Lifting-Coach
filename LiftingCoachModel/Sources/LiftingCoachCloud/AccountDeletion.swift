import Foundation

/// Asks the server to delete this account and everything it holds.
///
/// The phone can't do this itself, deliberately: its role has no delete
/// permission of any kind, because a backup the device can erase is a backup a
/// bug can erase. So deletion is one function, `server/`'s `delete_account`,
/// called through Lambda's own `Invoke` API and signed with the same
/// identity-pool credentials the phone uploads with. There is no URL to
/// configure and no public endpoint — the phone role holds
/// `lambda:InvokeFunction` on that one function and nothing else in Lambda.
///
/// **The access token is what decides whose account goes**, not the IAM
/// signature. The function hands it to Cognito's `GetUser`, which validates it
/// and names the `sub`; the token needs the `aws.cognito.signin.user.admin`
/// scope for that, which is why `HostedUI` asks for it. See INFRA-SPEC §9.4.
public struct AccountDeletion: Sendable {
    public let config: CloudConfig
    let transport: HTTPTransport

    public init(config: CloudConfig = .production, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public var url: URL {
        URL(string: "https://lambda.\(config.region).amazonaws.com/2015-03-31/functions/")!
            .appendingPathComponent(config.deleteAccountFunction)
            .appendingPathComponent("invocations")
    }

    /// Deletes the account and returns how many object versions went with it.
    ///
    /// Throws `.signInExpired` when the function refused the token, and
    /// `.http` for anything else — every step on the server is safe to repeat,
    /// so the answer to a failure is to try again.
    @discardableResult
    public func delete(accessToken: String, credentials: AWSCredentials) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["accessToken": accessToken])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        SigV4.sign(&request, credentials: credentials, region: config.region, service: "lambda",
                   payloadSHA256: SigV4.payloadHash(body))

        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw CloudError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        // Lambda answers 200 for an invocation that *ran*, including one whose
        // handler raised; the header is the only sign. Without this check a
        // crashed deletion would read as a successful one.
        if let failure = response.value(forHTTPHeaderField: "X-Amz-Function-Error") {
            throw CloudError.http(200, "Account deletion failed (\(failure)). Nothing was lost by trying — try again.")
        }

        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard reply["deleted"] as? Bool == true else {
            if reply["reason"] as? String == "signInRequired" { throw CloudError.signInExpired }
            throw CloudError.http(200, String(decoding: data, as: UTF8.self))
        }
        return reply["objectVersions"] as? Int ?? 0
    }
}

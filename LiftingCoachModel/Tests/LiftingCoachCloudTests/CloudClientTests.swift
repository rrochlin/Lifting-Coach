import Foundation
import Testing
@testable import LiftingCoachCloud

/// Answers with canned responses and records what would have been sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, [String: String], Data)]
    private(set) var sent: [URLRequest] = []

    init(_ responses: [(Int, [String: String], Data)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let (status, headers, body) = responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }
}

let fakeCredentials = AWSCredentials(accessKeyID: "AKID", secretAccessKey: "secret",
                                     sessionToken: "session", expiration: .distantFuture)

/// A JWT-shaped string carrying `claims`, unsigned — the phone never verifies
/// a token, so these tests don't need a real signature.
func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "e30.\(payload).sig"
}

func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

let appleSub = "001234.0123456789abcdef0123456789abcdef.0123"
let apple = AppleCredential(
    identityToken: jwt(["sub": appleSub, "email": "lifter@privaterelay.appleid.com"]),
    authorizationCode: "code", rawNonce: "raw"
)
let authResult = json(["AuthenticationResult": [
    "IdToken": "i", "AccessToken": "a", "RefreshToken": "r", "ExpiresIn": 3600,
]])

@Suite("User pool sign-in")
struct UserPoolAuthTests {
    @Test("The username is derived from Apple's sub, never the lifter's email")
    func username() {
        #expect(UserPoolAuth.username(forAppleSubject: appleSub) ==
            "001234.0123456789abcdef0123456789abcdef.0123@apple.lift-coach.invalid")
    }

    @Test("The nonce Apple embeds is the lowercase hex SHA-256 of the one the server is sent")
    func nonce() {
        // SHA-256("abc"), FIPS 180-2's first test vector.
        #expect(AppleNonce(raw: "abc").hashed ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("First sign-in: sign up, then answer the challenge with Apple's token")
    func firstSignIn() async throws {
        let transport = FakeTransport([
            (200, [:], json(["UserConfirmed": true])),
            (200, [:], json(["ChallengeName": "CUSTOM_CHALLENGE", "Session": "s1"])),
            (200, [:], authResult),
        ])
        let tokens = try await UserPoolAuth(transport: transport).signIn(apple)

        #expect(tokens.refreshToken == "r")
        #expect(tokens.displayEmail == "lifter@privaterelay.appleid.com")
        let targets = transport.sent.map { $0.value(forHTTPHeaderField: "X-Amz-Target") }
        #expect(targets == [
            "AWSCognitoIdentityProviderService.SignUp",
            "AWSCognitoIdentityProviderService.InitiateAuth",
            "AWSCognitoIdentityProviderService.RespondToAuthChallenge",
        ])
        let username = UserPoolAuth.username(forAppleSubject: appleSub)
        let signUp = body(transport.sent[0])
        #expect(signUp["Username"] as? String == username)
        #expect((signUp["ClientMetadata"] as? [String: String]) ==
            ["appleIdentityToken": apple.identityToken, "appleNonce": "raw"])
        let answer = body(transport.sent[2])
        #expect(answer["Session"] as? String == "s1")
        #expect((answer["ChallengeResponses"] as? [String: String]) ==
            ["USERNAME": username, "ANSWER": apple.identityToken])
        #expect((answer["ClientMetadata"] as? [String: String]) == ["appleNonce": "raw"])
    }

    @Test("An existing account is the normal case, not an error")
    func returningSignIn() async throws {
        let transport = FakeTransport([
            (400, [:], json(["__type": "UsernameExistsException", "message": "User already exists"])),
            (200, [:], json(["ChallengeName": "CUSTOM_CHALLENGE", "Session": "s1"])),
            (200, [:], authResult),
        ])
        let tokens = try await UserPoolAuth(transport: transport).signIn(apple)
        #expect(tokens.idToken == "i")
    }

    @Test("A trigger's refusal surfaces as a sign-in failure")
    func refused() async {
        let transport = FakeTransport([
            (400, [:], json(["__type": "UserLambdaValidationException",
                             "message": "PreSignUp failed with error Nonce mismatch."])),
        ])
        await #expect(throws: CognitoIdentityProviderError.self) {
            try await UserPoolAuth(transport: transport).signIn(apple)
        }
    }

    @Test("A refresh keeps the refresh token; a lapsed one reads as an expired sign-in")
    func refresh() async throws {
        let refreshed = json(["AuthenticationResult": ["IdToken": "i2", "AccessToken": "a2", "ExpiresIn": 3600]])
        let transport = FakeTransport([
            (200, [:], refreshed),
            (400, [:], json(["__type": "NotAuthorizedException", "message": "Refresh Token has expired"])),
        ])
        let auth = UserPoolAuth(transport: transport)
        let next = try await auth.refresh("r")
        #expect(next.idToken == "i2")
        #expect(next.refreshToken == "r")
        #expect((body(transport.sent[0])["AuthFlow"] as? String) == "REFRESH_TOKEN_AUTH")
        await #expect(throws: CloudError.signInExpired) { try await auth.refresh("old") }
    }

    @Test("Id token claims are read from the payload")
    func claims() throws {
        // {"sub":"a8f1","email":"x@y.z","exp":2000000000}, base64url, unpadded.
        let token = "e30.eyJzdWIiOiJhOGYxIiwiZW1haWwiOiJ4QHkueiIsImV4cCI6MjAwMDAwMDAwMH0.sig"
        let claims = try IDTokenClaims(jwt: token)
        #expect(claims.subject == "a8f1")
        #expect(claims.email == "x@y.z")
        #expect(claims.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test("Tokens stored before displayEmail existed still load")
    func storedTokensDecode() throws {
        let old = Data(#"{"idToken":"i","accessToken":"a","refreshToken":"r","expiresAt":0}"#.utf8)
        let tokens = try JSONDecoder().decode(CognitoTokens.self, from: old)
        #expect(tokens.displayEmail == nil)
    }
}

@Suite("Snapshot bucket")
struct SnapshotBucketTests {
    @Test("The key is the user pool sub's prefix")
    func key() {
        #expect(SnapshotBucket().url(for: "a8f1").absoluteString ==
            "https://lift-coach-prod-snapshots.s3.us-west-2.amazonaws.com/users/a8f1/snapshot.sqlite.gz")
    }

    @Test("Each precondition sends exactly its header")
    func preconditions() async throws {
        let ok: (Int, [String: String], Data) = (200, ["ETag": "\"new\""], Data())
        let transport = FakeTransport([ok, ok, ok])
        let bucket = SnapshotBucket(transport: transport)

        for precondition in [WritePrecondition.noExistingObject, .unchangedSince(etag: "\"old\""), .overwrite] {
            _ = try await bucket.put(Data("x".utf8), subject: "s", precondition: precondition,
                                     deviceID: "d", credentials: fakeCredentials)
        }
        #expect(transport.sent[0].value(forHTTPHeaderField: "If-None-Match") == "*")
        #expect(transport.sent[0].value(forHTTPHeaderField: "If-Match") == nil)
        #expect(transport.sent[1].value(forHTTPHeaderField: "If-Match") == "\"old\"")
        #expect(transport.sent[2].value(forHTTPHeaderField: "If-Match") == nil)
        #expect(transport.sent[2].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("A PUT is checksummed, signed, and returns the new etag")
    func putHeaders() async throws {
        let transport = FakeTransport([(200, ["ETag": "\"e1\""], Data())])
        let etag = try await SnapshotBucket(transport: transport)
            .put(Data("hello".utf8), subject: "s", precondition: .overwrite,
                 deviceID: "phone", credentials: fakeCredentials)
        let sent = transport.sent[0]
        #expect(etag == "\"e1\"")
        // base64(sha256("hello"))
        #expect(sent.value(forHTTPHeaderField: "x-amz-checksum-sha256") ==
            "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=")
        #expect(sent.value(forHTTPHeaderField: "x-amz-meta-device-id") == "phone")
        #expect(sent.value(forHTTPHeaderField: "x-amz-security-token") == "session")
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
    }

    @Test("A refused precondition is the single-writer signal, not a failure to retry")
    func conflict() async {
        for status in [412, 409] {
            let transport = FakeTransport([(status, [:], Data())])
            await #expect(throws: CloudError.cloudCopyChanged) {
                _ = try await SnapshotBucket(transport: transport)
                    .put(Data(), subject: "s", precondition: .noExistingObject,
                         deviceID: "d", credentials: fakeCredentials)
            }
        }
    }

    @Test("HEAD on a key that isn't there reads as no snapshot, whether S3 says 403 or 404")
    func headMissing() async throws {
        for status in [403, 404] {
            let transport = FakeTransport([(status, [:], Data())])
            let remote = try await SnapshotBucket(transport: transport)
                .head(subject: "s", credentials: fakeCredentials)
            #expect(remote == nil)
        }
    }
}

@Suite("Account deletion")
struct AccountDeletionTests {
    @Test("Deletion is a signed Lambda Invoke carrying the access token")
    func request() async throws {
        let transport = FakeTransport([(200, [:], json(["deleted": true, "objectVersions": 3]))])
        let removed = try await AccountDeletion(transport: transport)
            .delete(accessToken: "access-token", appleAuthorizationCode: "apple-code", credentials: fakeCredentials)

        #expect(removed == 3)
        let sent = try #require(transport.sent.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString ==
            "https://lambda.us-west-2.amazonaws.com/2015-03-31/functions/lift-coach-prod-delete-account/invocations")
        let auth = sent.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(auth.contains("/us-west-2/lambda/aws4_request"))
        #expect(sent.value(forHTTPHeaderField: "X-Amz-Security-Token") == "session")
        let payload = try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: String]
        #expect(payload == ["accessToken": "access-token", "appleAuthorizationCode": "apple-code"])
    }

    /// Lambda answers 200 for an invocation that ran, including one that
    /// crashed. Reading that as success would tell the lifter their data was
    /// deleted while it sat in the bucket.
    @Test("A handler that raised is a failure, even inside a 200")
    func functionError() async {
        let transport = FakeTransport([(200, ["X-Amz-Function-Error": "Unhandled"],
                                        json(["errorMessage": "boom"]))])
        await #expect(throws: CloudError.self) {
            try await AccountDeletion(transport: transport)
                .delete(accessToken: "t", appleAuthorizationCode: "c", credentials: fakeCredentials)
        }
    }

    @Test("A refused token reads as needing to sign in again")
    func refused() async {
        let transport = FakeTransport([(200, [:], json(["deleted": false, "reason": "signInRequired"]))])
        await #expect(throws: CloudError.signInExpired) {
            try await AccountDeletion(transport: transport)
                .delete(accessToken: "t", appleAuthorizationCode: "c", credentials: fakeCredentials)
        }
    }

    @Test("IAM refusing the invoke is a failure")
    func forbidden() async {
        let transport = FakeTransport([(403, [:], Data("AccessDenied".utf8))])
        await #expect(throws: CloudError.http(403, "AccessDenied")) {
            try await AccountDeletion(transport: transport)
                .delete(accessToken: "t", appleAuthorizationCode: "c", credentials: fakeCredentials)
        }
    }

    @Test("Apple refusing the confirmation, or a different Apple ID, deletes nothing and says why")
    func appleRefusals() async {
        for (reason, error) in [("appleReconfirmationRequired", CloudError.appleReconfirmationRequired),
                                ("appleAccountMismatch", CloudError.appleAccountMismatch)] {
            let transport = FakeTransport([(200, [:], json(["deleted": false, "reason": reason]))])
            await #expect(throws: error) {
                try await AccountDeletion(transport: transport)
                    .delete(accessToken: "t", appleAuthorizationCode: "c", credentials: fakeCredentials)
            }
        }
    }
}

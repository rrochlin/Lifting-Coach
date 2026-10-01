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

@Suite("Hosted UI")
struct HostedUITests {
    @Test("The PKCE challenge matches RFC 7636's worked example")
    func pkceVector() {
        let attempt = HostedUI.Attempt(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        #expect(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("The authorize URL carries the challenge, never the verifier")
    func authorizeURL() {
        let attempt = HostedUI.Attempt(verifier: "secret-verifier", state: "abc")
        let url = HostedUI().authorizeURL(for: attempt).absoluteString
        #expect(url.hasPrefix("https://lift-coach-prod.auth.us-west-2.amazoncognito.com/oauth2/authorize?"))
        #expect(url.contains("code_challenge=\(attempt.challenge)"))
        #expect(url.contains("code_challenge_method=S256"))
        #expect(url.contains("state=abc"))
        #expect(!url.contains("secret-verifier"))
        // No identity_provider: the Hosted UI offers email and Apple both.
        #expect(!url.contains("identity_provider"))
    }

    @Test("A redirect for a different attempt is refused")
    func stateMismatch() {
        let attempt = HostedUI.Attempt(verifier: "v", state: "mine")
        let callback = URL(string: "liftcoach://callback?code=abc&state=theirs")!
        #expect(throws: CloudError.signInStateMismatch) {
            try HostedUI().code(from: callback, for: attempt)
        }
    }

    @Test("A redirect carrying an error surfaces it")
    func callbackError() {
        let attempt = HostedUI.Attempt(verifier: "v", state: "s")
        let callback = URL(string: "liftcoach://callback?error=access_denied&error_description=cancelled&state=s")!
        #expect(throws: CloudError.signInRejected("cancelled")) {
            try HostedUI().code(from: callback, for: attempt)
        }
    }

    @Test("The token exchange sends the verifier, and a refresh keeps the old refresh token")
    func exchangeAndRefresh() async throws {
        let body = Data(#"{"id_token":"i","access_token":"a","refresh_token":"r","expires_in":3600}"#.utf8)
        let refreshed = Data(#"{"id_token":"i2","access_token":"a2","expires_in":3600}"#.utf8)
        let transport = FakeTransport([(200, [:], body), (200, [:], refreshed)])
        let ui = HostedUI(transport: transport)
        let attempt = HostedUI.Attempt(verifier: "the-verifier", state: "s")

        let tokens = try await ui.exchange(code: "c", for: attempt)
        #expect(tokens.refreshToken == "r")
        let form = String(decoding: transport.sent[0].httpBody!, as: UTF8.self)
        #expect(form.contains("code_verifier=the-verifier"))
        #expect(form.contains("redirect_uri=liftcoach%3A%2F%2Fcallback"))

        // Cognito doesn't rotate refresh tokens; losing it here would sign the
        // lifter out on the first refresh.
        let next = try await ui.refresh("r")
        #expect(next.idToken == "i2")
        #expect(next.refreshToken == "r")
    }

    @Test("A lapsed refresh token reads as an expired sign-in")
    func refreshExpired() async {
        let transport = FakeTransport([(400, [:], Data(#"{"error":"invalid_grant"}"#.utf8))])
        await #expect(throws: CloudError.signInExpired) {
            try await HostedUI(transport: transport).refresh("old")
        }
    }

    @Test("Id token claims are read from the payload")
    func claims() throws {
        // {"sub":"a8f1","email":"x@y.z","exp":2000000000}, base64url, unpadded.
        let jwt = "e30.eyJzdWIiOiJhOGYxIiwiZW1haWwiOiJ4QHkueiIsImV4cCI6MjAwMDAwMDAwMH0.sig"
        let claims = try IDTokenClaims(jwt: jwt)
        #expect(claims.subject == "a8f1")
        #expect(claims.email == "x@y.z")
        #expect(claims.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
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

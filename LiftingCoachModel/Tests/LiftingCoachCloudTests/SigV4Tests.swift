import Foundation
import Testing
@testable import LiftingCoachCloud

/// The signer, checked against AWS's own worked examples.
///
/// A signing bug never fails loudly — it produces a well-formed request that S3
/// answers with `SignatureDoesNotMatch` — so the only trustworthy check is a
/// published signature computed by someone else. These are the examples from
/// the S3 documentation's "Authenticating Requests: Using the Authorization
/// Header" (the GET Object and PUT Object walk-throughs), which use the
/// documentation's example key pair and a fixed date.
@Suite("SigV4")
struct SigV4Tests {
    let credentials = AWSCredentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        sessionToken: nil,
        expiration: .distantFuture
    )

    /// 2013-05-24T00:00:00Z, the instant every documentation example uses.
    let date = Date(timeIntervalSince1970: 1_369_353_600)

    @Test("GET Object matches the S3 documentation's signature")
    func getObject() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")

        SigV4.sign(
            &request, credentials: credentials, region: "us-east-1", service: "s3",
            payloadSHA256: SigV4.emptyPayloadHash, date: date
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
            + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
            + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test("PUT Object matches the S3 documentation's signature")
    func putObject() {
        // The documentation's example body, and the date header it signs.
        let body = Data("Welcome to Amazon S3.".utf8)
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test$file.text")!)
        request.httpMethod = "PUT"
        request.setValue("Fri, 24 May 2013 00:00:00 GMT", forHTTPHeaderField: "Date")
        request.setValue("REDUCED_REDUNDANCY", forHTTPHeaderField: "x-amz-storage-class")

        SigV4.sign(
            &request, credentials: credentials, region: "us-east-1", service: "s3",
            payloadSHA256: SigV4.payloadHash(body), date: date
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
            + "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, "
            + "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    @Test("A session token is sent and signed")
    func sessionToken() {
        var creds = credentials
        creds.sessionToken = "token-value"
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/a")!)
        SigV4.sign(&request, credentials: creds, region: "us-west-2", service: "s3",
                   payloadSHA256: SigV4.emptyPayloadHash, date: date)

        #expect(request.value(forHTTPHeaderField: "x-amz-security-token") == "token-value")
        #expect(request.value(forHTTPHeaderField: "Authorization")?
            .contains("x-amz-security-token") == true)
    }

    @Test("A precondition header is signed, so it can't be stripped in transit")
    func conditionalHeaderIsSigned() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/a")!)
        request.httpMethod = "PUT"
        request.setValue("\"abc\"", forHTTPHeaderField: "If-Match")
        SigV4.sign(&request, credentials: credentials, region: "us-west-2", service: "s3",
                   payloadSHA256: SigV4.emptyPayloadHash, date: date)

        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("if-match") == true)
    }

    @Test("Path segments are encoded once, slashes kept")
    func pathEncoding() {
        let url = URL(string: "https://b.s3.amazonaws.com/users/a%20b/snap$shot.gz")!
        #expect(SigV4.canonicalPath(url) == "/users/a%20b/snap%24shot.gz")
    }
}

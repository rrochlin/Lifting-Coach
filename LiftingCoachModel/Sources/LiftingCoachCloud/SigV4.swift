import CryptoKit
import Foundation

/// Temporary AWS credentials, as the Cognito identity pool hands them out.
public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String
    /// Present for every credential the phone ever holds — identity-pool
    /// credentials are always session credentials — but optional so the AWS
    /// documentation's long-term-key test vectors can be checked as written.
    public var sessionToken: String?
    public var expiration: Date

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String?, expiration: Date) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }
}

/// AWS Signature Version 4, for exactly the requests the phone makes.
///
/// Written by hand rather than taken from the AWS SDK or Amplify, which would
/// each add a large dependency to sign four kinds of request — and because the
/// conditional PUT this design relies on (`If-Match`) is a header we'd be
/// setting by hand regardless. The cost is owning the signer, which is why
/// `SigV4Tests` checks it against AWS's own published example signatures: an
/// error here doesn't fail loudly, it produces a well-formed request that S3
/// answers with `SignatureDoesNotMatch`.
///
/// Scope is deliberately narrow: header-based signing (no presigned URLs), and
/// the payload hash supplied by the caller, because S3 wants it sent as
/// `x-amz-content-sha256` anyway.
public enum SigV4 {
    /// Signs `request` in place, adding `x-amz-date`, `x-amz-content-sha256`,
    /// `x-amz-security-token` (when the credentials carry one) and
    /// `Authorization`.
    ///
    /// Every header already on the request is signed. That's the safe default
    /// for a client this small: an unsigned `If-Match` would let anything on
    /// the path strip the precondition and turn a conditional write into a
    /// blind overwrite.
    public static func sign(
        _ request: inout URLRequest,
        credentials: AWSCredentials,
        region: String,
        service: String,
        payloadSHA256: String,
        date: Date = Date()
    ) {
        let (amzDate, dateStamp) = timestamps(date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadSHA256, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }
        guard let url = request.url, let host = url.host else { return }

        var headers: [String: String] = ["host": host]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let signedNames = headers.keys.sorted()
        let canonicalHeaders = signedNames.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = signedNames.joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalPath(url),
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadSHA256,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        let signature = hex(
            hmac(signingKey(credentials.secretAccessKey, dateStamp, region, service), stringToSign)
        )
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// The hex SHA-256 of a body, which is what `x-amz-content-sha256` carries.
    public static func payloadHash(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// The hash S3 expects for a request with no body.
    public static let emptyPayloadHash = payloadHash(Data())

    // MARK: Pieces, internal so the tests can check each against AWS's examples

    static func timestamps(_ date: Date) -> (amzDate: String, dateStamp: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        return (amzDate, String(amzDate.prefix(8)))
    }

    /// S3 canonical paths are URI-encoded once per segment, with `/` kept.
    /// (Every other service encodes twice; S3 is the documented exception.)
    static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0)) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return ""
        }
        let pairs: [(name: String, value: String)] = items.map {
            (uriEncode($0.name), uriEncode($0.value ?? ""))
        }
        let sorted = pairs.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// RFC 3986 unreserved characters pass; everything else is `%XX`, upper
    /// case. Foundation's own sets are close and not equal — `urlPathAllowed`
    /// leaves `:` and `@` unescaped, which AWS doesn't.
    static func uriEncode(_ string: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    static func signingKey(_ secret: String, _ dateStamp: String, _ region: String, _ service: String) -> SymmetricKey {
        let kDate = hmac(SymmetricKey(data: Data("AWS4\(secret)".utf8)), dateStamp)
        let kRegion = hmac(SymmetricKey(data: kDate), region)
        let kService = hmac(SymmetricKey(data: kRegion), service)
        return SymmetricKey(data: hmac(SymmetricKey(data: kService), "aws4_request"))
    }

    static func hmac(_ key: SymmetricKey, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

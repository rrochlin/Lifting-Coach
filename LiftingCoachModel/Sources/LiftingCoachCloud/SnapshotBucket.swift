import CryptoKit
import Foundation

/// What S3 holds for this account, from a HEAD — the phone has no DynamoDB
/// access, so this is how it learns what's in the cloud (INFRA-SPEC §6).
public struct RemoteSnapshot: Sendable, Equatable {
    public var etag: String
    public var byteCount: Int
    public var lastModified: Date?

    public init(etag: String, byteCount: Int, lastModified: Date?) {
        self.etag = etag
        self.byteCount = byteCount
        self.lastModified = lastModified
    }
}

/// How a PUT is allowed to land.
public enum WritePrecondition: Sendable, Equatable {
    /// Only if nothing is there yet — the first upload from this device. A
    /// reinstalled phone holds a fresh database and has forgotten its last
    /// etag, so a blind first upload would overwrite the real backup with an
    /// empty log. This turns that into a question for the lifter instead.
    case noExistingObject
    /// Only if the object is still the one this device last wrote.
    case unchangedSince(etag: String)
    /// Overwrite whatever is there. Only ever chosen by the lifter, after being
    /// told the cloud copy changed.
    case overwrite
}

/// The phone's one object: `users/{sub}/snapshot.sqlite.gz`.
///
/// Every request is SigV4-signed with identity-pool credentials, which the
/// bucket's IAM policy scopes to this account's prefix. The bucket encrypts
/// with its default KMS key, so no encryption header is sent; it is TLS-only,
/// which `https` satisfies.
public struct SnapshotBucket: Sendable {
    public let config: CloudConfig
    let transport: HTTPTransport

    public static let filename = "snapshot.sqlite.gz"

    public init(config: CloudConfig = .production, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public func url(for subject: String) -> URL {
        URL(string: "https://\(config.bucket).s3.\(config.region).amazonaws.com/users/")!
            .appendingPathComponent(subject)
            .appendingPathComponent(Self.filename)
    }

    /// Uploads, conditionally, and returns the new etag.
    ///
    /// `x-amz-checksum-sha256` makes S3 verify the body before accepting it, so
    /// a corrupted transfer is impossible rather than merely detectable later.
    /// `device-id` is advisory metadata the server copies into its index for
    /// log lines and trusts for nothing else.
    public func put(
        _ body: Data,
        subject: String,
        precondition: WritePrecondition,
        deviceID: String,
        credentials: AWSCredentials
    ) async throws -> String {
        var request = URLRequest(url: url(for: subject))
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue(
            Data(SHA256.hash(data: body)).base64EncodedString(),
            forHTTPHeaderField: "x-amz-checksum-sha256"
        )
        request.setValue(deviceID, forHTTPHeaderField: "x-amz-meta-device-id")
        switch precondition {
        case .noExistingObject: request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .unchangedSince(let etag): request.setValue(etag, forHTTPHeaderField: "If-Match")
        case .overwrite: break
        }
        SigV4.sign(&request, credentials: credentials, region: config.region, service: "s3",
                   payloadSHA256: SigV4.payloadHash(body))

        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200:
            guard let etag = response.value(forHTTPHeaderField: "ETag") else {
                throw CloudError.http(200, "PUT returned no ETag")
            }
            return etag
        case 412:
            throw CloudError.cloudCopyChanged
        case 409:
            // A concurrent conditional write to the same key. Same meaning for
            // the lifter as a 412: someone else wrote.
            throw CloudError.cloudCopyChanged
        default:
            throw CloudError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    /// `nil` when this account has never uploaded.
    public func head(subject: String, credentials: AWSCredentials) async throws -> RemoteSnapshot? {
        var request = URLRequest(url: url(for: subject))
        request.httpMethod = "HEAD"
        SigV4.sign(&request, credentials: credentials, region: config.region, service: "s3",
                   payloadSHA256: SigV4.emptyPayloadHash)
        let (_, response) = try await transport.send(request)
        switch response.statusCode {
        case 200:
            return RemoteSnapshot(
                etag: response.value(forHTTPHeaderField: "ETag") ?? "",
                byteCount: Int(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
                lastModified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
            )
        // The role has no s3:ListBucket, so S3 says 403 rather than 404 for a
        // key that doesn't exist — it won't reveal existence to a caller who
        // can't list. Both mean "nothing here" for this account's own key.
        case 403, 404:
            return nil
        default:
            throw CloudError.http(response.statusCode, "")
        }
    }

    public func get(subject: String, credentials: AWSCredentials) async throws -> (Data, RemoteSnapshot) {
        var request = URLRequest(url: url(for: subject))
        request.httpMethod = "GET"
        SigV4.sign(&request, credentials: credentials, region: config.region, service: "s3",
                   payloadSHA256: SigV4.emptyPayloadHash)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw CloudError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        let remote = RemoteSnapshot(
            etag: response.value(forHTTPHeaderField: "ETag") ?? "",
            byteCount: data.count,
            lastModified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
        )
        return (data, remote)
    }

    static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}

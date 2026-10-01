import Foundation
import LiftingCoachPersistence

/// Remembers the digest of the last snapshot that made it to S3, per account.
///
/// `UserDefaults` because this is bookkeeping about a *remote* object, and the
/// obvious-looking alternative is actively broken: putting the watermark in the
/// database would mean every upload changed the thing the watermark describes,
/// so the next digest would differ, so another upload would be due, forever.
///
/// Losing it costs exactly one redundant upload — the next trigger finds no
/// watermark, exports, and sends bytes the bucket already has. That's the right
/// failure direction for a cache, and it's why nothing here is defensive.
///
/// `@unchecked` because `UserDefaults` predates `Sendable` and has never been
/// annotated, not because anything here is unsafe: it's documented as thread
/// safe, and this reads and writes two strings.
public struct UserDefaultsWatermarkStore: SnapshotWatermarkStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func watermark(for account: String) -> String? {
        defaults.string(forKey: Self.key(account))
    }

    public func etag(for account: String) -> String? {
        defaults.string(forKey: Self.etagKey(account))
    }

    /// Losing the etag is not like losing the digest. Without it the next
    /// upload is made as a *first* upload, which S3 refuses because the object
    /// exists — so a cleared store surfaces as "the cloud copy changed", and the
    /// lifter is asked rather than anything being overwritten. The safe
    /// direction again, at the cost of a question.
    public func setWatermark(_ sha256: String?, etag: String?, for account: String) {
        defaults.set(sha256, forKey: Self.key(account))
        defaults.set(etag, forKey: Self.etagKey(account))
    }

    private static func etagKey(_ account: String) -> String {
        "snapshot.etag.\(account)"
    }

    /// Keyed by account, so signing in as somebody else can't inherit a claim
    /// that their training log is already in the bucket.
    private static func key(_ account: String) -> String {
        "snapshot.watermark.\(account)"
    }
}

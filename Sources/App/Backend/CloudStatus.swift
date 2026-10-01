import Foundation

/// What Profile shows about the cloud copy, held on `AppEnvironment`.
public struct CloudStatus: Equatable {
    public var session: AuthSession?
    /// What S3 holds for this account, from a HEAD.
    public var remote: SnapshotDescriptor?
    /// Set when this session uploaded; the remote's own date covers the rest.
    public var lastBackup: Date?
    /// S3 refused a conditional write: the cloud copy changed since this phone
    /// last wrote it. Nothing uploads until the lifter chooses.
    public var hasConflict = false
    public var failure: String?
    /// A restore is downloaded and waits for the next launch.
    public var restoreStaged = false
    /// What a staged restore did at this launch, reported once.
    var launchRestore: PendingRestore.Outcome?

    public init() {}
}

public enum AccountError: LocalizedError {
    case boundToAnotherAccount

    public var errorDescription: String? {
        switch self {
        case .boundToAnotherAccount:
            // Email and Sign in with Apple are separate accounts, which is the
            // usual way to land here — so the message names that, not just
            // the refusal.
            "This phone's training log already belongs to a different account. If you signed in before with the other method — email or Apple — sign in that way instead."
        }
    }
}

public enum CloudActionError: LocalizedError {
    case notSignedIn
    case restoreWouldDiscard(Int)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Not signed in."
        case .restoreWouldDiscard(let count):
            "Not restored: \(count) workout\(count == 1 ? "" : "s") on this phone aren't in the cloud backup, and restoring would delete them. Back up this phone's data instead, or remove those workouts first."
        }
    }
}

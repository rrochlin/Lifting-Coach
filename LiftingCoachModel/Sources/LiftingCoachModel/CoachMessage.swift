import Foundation

/// One message in the coach conversation (INFRA-SPEC §13).
///
/// The conversation lives on the phone. The lifter's messages carry a
/// delivery `status`; the coach's are only ever written once they've arrived,
/// so they're always `.sent`.
public struct CoachMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable, Codable {
        case lifter
        case coach
    }

    public enum Status: Hashable, Sendable {
        /// Written, not yet answered. Sent (or re-sent) until it is.
        case pending
        case sent
        /// Refused for a reason sending again won't fix. Kept, shown, and
        /// retryable by hand — never silently dropped.
        case failed(String)
    }

    /// The lifter's messages use a UUID made on the phone; the server derives
    /// each reply's id from the message it answers (`<id>-reply`), so a reply
    /// delivered twice is the same row both times.
    public var id: String
    public var role: Role
    public var text: String
    public var createdAt: Date
    public var status: Status
    /// On a reply: the lifter's message it answers.
    public var inReplyTo: String?

    public init(
        id: String, role: Role, text: String, createdAt: Date,
        status: Status = .sent, inReplyTo: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.status = status
        self.inReplyTo = inReplyTo
    }

    /// The longest message the server accepts (`coach.MESSAGE_LIMIT`).
    public static let characterLimit = 4000
}

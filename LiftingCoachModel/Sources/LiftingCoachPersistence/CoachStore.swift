import Foundation
import GRDB
import LiftingCoachModel

private struct CoachMessageRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "coachMessage"

    var id: String
    var role: String
    var text: String
    var createdAt: Date
    var status: String
    var failure: String?
    var inReplyTo: String?

    init(_ message: CoachMessage) {
        id = message.id
        role = message.role.rawValue
        text = message.text
        createdAt = message.createdAt
        inReplyTo = message.inReplyTo
        switch message.status {
        case .pending: status = "pending"; failure = nil
        case .sent: status = "sent"; failure = nil
        case .failed(let reason): status = "failed"; failure = reason
        }
    }

    var message: CoachMessage {
        let resolved: CoachMessage.Status = switch status {
        case "pending": .pending
        case "failed": .failed(failure ?? "")
        default: .sent
        }
        return CoachMessage(
            id: id, role: CoachMessage.Role(rawValue: role) ?? .coach, text: text,
            createdAt: createdAt, status: resolved, inReplyTo: inReplyTo
        )
    }
}

/// The coach conversation, on disk. See `CoachMessage` and `CoachOutbox`.
public struct CoachStore: Sendable {
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    /// The whole conversation, oldest first.
    public func all() throws -> [CoachMessage] {
        try database.writer.read { db in
            try CoachMessageRow.order(Column("createdAt"), Column("id")).fetchAll(db).map(\.message)
        }
    }

    /// Writes the lifter's message as `pending` — before anything is sent, so
    /// there is no moment at which it exists only in memory.
    @discardableResult
    public func addPending(_ text: String, id: String = UUID().uuidString, at date: Date = Date()) throws -> CoachMessage {
        let message = CoachMessage(id: id, role: .lifter, text: text, createdAt: date, status: .pending)
        try database.writer.write { db in try CoachMessageRow(message).insert(db) }
        return message
    }

    /// Stores a reply and marks the message it answers sent, in one
    /// transaction — so a crash between the two can't leave a message
    /// answered but still pending (sent again) or sent with no reply.
    ///
    /// Storing the same reply twice is a no-op: re-delivery is expected.
    public func deliver(reply: CoachMessage, answering messageID: String) throws {
        try database.writer.write { db in
            if try CoachMessageRow.fetchOne(db, key: reply.id) == nil {
                try CoachMessageRow(reply).insert(db)
            }
            try db.execute(
                sql: "UPDATE coachMessage SET status = 'sent', failure = NULL WHERE id = ?",
                arguments: [messageID]
            )
        }
    }

    public func markFailed(_ messageID: String, reason: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE coachMessage SET status = 'failed', failure = ? WHERE id = ?",
                arguments: [reason, messageID]
            )
        }
    }

    /// Puts a failed message back in the queue, for RETRY.
    public func markPending(_ messageID: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE coachMessage SET status = 'pending', failure = NULL WHERE id = ? AND role = 'lifter'",
                arguments: [messageID]
            )
        }
    }
}

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
    var conversationId: String?
    var memoryChanges: String?

    init(_ message: CoachMessage) {
        id = message.id
        role = message.role.rawValue
        text = message.text
        createdAt = message.createdAt
        inReplyTo = message.inReplyTo
        conversationId = message.conversationID
        memoryChanges = message.memoryChanges.isEmpty
            ? nil
            : (try? JSONEncoder().encode(message.memoryChanges)).flatMap { String(data: $0, encoding: .utf8) }
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
        let changes = memoryChanges
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([CoachMemoryChange].self, from: $0) } ?? []
        return CoachMessage(
            id: id, role: CoachMessage.Role(rawValue: role) ?? .coach, text: text,
            createdAt: createdAt, status: resolved, inReplyTo: inReplyTo,
            conversationID: conversationId, memoryChanges: changes
        )
    }
}

private struct CoachConversationRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "coachConversation"

    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var subject: String?

    var conversation: CoachConversation {
        CoachConversation(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt)
    }
}

private struct CoachMemoryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "coachMemory"

    var id: String
    var category: String
    var text: String
    var source: String
    var updatedAt: Date

    var entry: CoachMemoryEntry? {
        CoachMemoryEntry.Category(rawValue: category).map {
            CoachMemoryEntry(
                id: id, category: $0, text: text,
                source: CoachMemoryEntry.Source(rawValue: source) ?? .coach, updatedAt: updatedAt
            )
        }
    }
}

/// The coach conversations and the lifter profile, on disk — INFRA-SPEC §13.
/// See `CoachMessage`, `CoachMemoryEntry` and `CoachOutbox`.
public struct CoachStore: Sendable {
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    // MARK: Conversations

    /// Newest first: the list on the Coach tab.
    public func conversations() throws -> [CoachConversation] {
        try database.writer.read { db in
            try CoachConversationRow.order(Column("updatedAt").desc).fetchAll(db).map(\.conversation)
        }
    }

    /// One conversation's messages, oldest first.
    public func messages(in conversationID: String) throws -> [CoachMessage] {
        try database.writer.read { db in
            try CoachMessageRow
                .filter(Column("conversationId") == conversationID)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db).map(\.message)
        }
    }

    /// Every message, oldest first — what the outbox delivers from.
    public func all() throws -> [CoachMessage] {
        try database.writer.read { db in
            try CoachMessageRow.order(Column("createdAt"), Column("id")).fetchAll(db).map(\.message)
        }
    }

    public func deleteConversation(_ id: String) throws {
        try database.writer.write { db in
            // Messages go with it (cascade).
            _ = try CoachConversationRow.deleteOne(db, key: id)
        }
    }

    // MARK: Messages

    /// Writes the lifter's message as `pending` — before anything is sent, so
    /// there is no moment at which it exists only in memory.
    ///
    /// With no conversation, starts one, titled by this message. Conversations
    /// are created by their first message rather than by a "+", so there are
    /// never empty ones in the list.
    @discardableResult
    public func addPending(
        _ text: String, in conversationID: String? = nil,
        id: String = UUID().uuidString, at date: Date = Date()
    ) throws -> CoachMessage {
        try database.writer.write { db in
            let conversation: String
            if let conversationID, try CoachConversationRow.fetchOne(db, key: conversationID) != nil {
                conversation = conversationID
                try db.execute(
                    sql: "UPDATE coachConversation SET updatedAt = ? WHERE id = ?",
                    arguments: [date, conversationID]
                )
            } else {
                conversation = UUID().uuidString
                try CoachConversationRow(
                    id: conversation, title: CoachConversation.title(from: text),
                    createdAt: date, updatedAt: date, subject: nil
                ).insert(db)
            }
            let message = CoachMessage(
                id: id, role: .lifter, text: text, createdAt: date, status: .pending,
                conversationID: conversation
            )
            try CoachMessageRow(message).insert(db)
            return message
        }
    }

    /// Stores a reply, applies the profile changes it carries, and marks the
    /// message it answers sent — **in one transaction**, so a crash between
    /// them can't leave a message answered but still pending (sent again), or
    /// a profile changed by a reply that was never stored.
    ///
    /// **Only the first time.** Re-delivery is expected (a reply lost on the
    /// way back is fetched again, with the same changes), so a reply already
    /// stored applies nothing a second time.
    public func deliver(reply: CoachMessage, answering messageID: String) throws {
        try database.writer.write { db in
            let conversation = try String.fetchOne(
                db, sql: "SELECT conversationId FROM coachMessage WHERE id = ?", arguments: [messageID]
            )
            if try CoachMessageRow.fetchOne(db, key: reply.id) == nil {
                var stored = reply
                stored.conversationID = conversation
                stored.memoryChanges = reply.memoryChanges.filter(\.isValid)
                try CoachMessageRow(stored).insert(db)
                try apply(stored.memoryChanges, at: reply.createdAt, in: db)
                if let conversation {
                    try db.execute(
                        sql: "UPDATE coachConversation SET updatedAt = ? WHERE id = ?",
                        arguments: [reply.createdAt, conversation]
                    )
                }
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

    // MARK: The lifter profile

    /// Everything the coach knows, grouped by category in the order the
    /// categories are listed, oldest first within each.
    public func memory() throws -> [CoachMemoryEntry] {
        let entries = try database.writer.read { db in
            try CoachMemoryRow.order(Column("updatedAt")).fetchAll(db).compactMap(\.entry)
        }
        let order = CoachMemoryEntry.Category.allCases
        return entries.sorted {
            (order.firstIndex(of: $0.category) ?? 0) < (order.firstIndex(of: $1.category) ?? 0)
        }
    }

    /// The lifter's edit. Marked as theirs, which the coach is told.
    public func editMemory(_ id: String, text: String, at date: Date = Date()) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= CoachMemoryEntry.textLimit else { return }
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE coachMemory SET text = ?, source = 'lifter', updatedAt = ? WHERE id = ?",
                arguments: [trimmed, date, id]
            )
        }
    }

    /// The lifter adding something themselves.
    @discardableResult
    public func addMemory(
        _ text: String, category: CoachMemoryEntry.Category, at date: Date = Date()
    ) throws -> CoachMemoryEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= CoachMemoryEntry.textLimit else { return nil }
        let entry = CoachMemoryEntry(
            id: "p-\(UUID().uuidString.prefix(12).lowercased())", category: category,
            text: trimmed, source: .lifter, updatedAt: date
        )
        try database.writer.write { db in
            guard try CoachMemoryRow.fetchCount(db) < CoachMemoryEntry.entryLimit else { return }
            try CoachMemoryRow(
                id: entry.id, category: category.rawValue, text: trimmed,
                source: "lifter", updatedAt: date
            ).insert(db)
        }
        return entry
    }

    public func deleteMemory(_ id: String) throws {
        try database.writer.write { db in _ = try CoachMemoryRow.deleteOne(db, key: id) }
    }

    public func clearMemory() throws {
        try database.writer.write { db in _ = try CoachMemoryRow.deleteAll(db) }
    }

    private func apply(_ changes: [CoachMemoryChange], at date: Date, in db: Database) throws {
        for change in changes {
            switch change.op {
            case .add:
                guard try CoachMemoryRow.fetchCount(db) < CoachMemoryEntry.entryLimit,
                      try CoachMemoryRow.fetchOne(db, key: change.id) == nil
                else { continue }
                try CoachMemoryRow(
                    id: change.id, category: change.category,
                    text: change.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    source: "coach", updatedAt: date
                ).insert(db)
            case .update:
                try db.execute(
                    sql: "UPDATE coachMemory SET text = ?, source = 'coach', updatedAt = ? WHERE id = ?",
                    arguments: [change.text.trimmingCharacters(in: .whitespacesAndNewlines), date, change.id]
                )
            case .remove:
                _ = try CoachMemoryRow.deleteOne(db, key: change.id)
            }
        }
    }
}

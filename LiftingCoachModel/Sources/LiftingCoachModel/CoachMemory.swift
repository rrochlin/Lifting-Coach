import Foundation

/// One fact the coach knows about the lifter — the lifter profile
/// (INFRA-SPEC §13.7). The coach writes it as it learns; the lifter can always
/// read, edit and delete it.
public struct CoachMemoryEntry: Identifiable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case goals, experience, constraints, preferences, notes

        public var title: String {
            switch self {
            case .goals: "Goals"
            case .experience: "Experience"
            case .constraints: "Constraints"
            case .preferences: "Preferences"
            case .notes: "Notes"
            }
        }
    }

    public enum Source: String, Sendable {
        /// Written by the coach.
        case coach
        /// Written or edited by the lifter — and shown to the coach as their
        /// own words.
        case lifter
    }

    public var id: String
    public var category: Category
    public var text: String
    public var source: Source
    public var updatedAt: Date

    public init(id: String, category: Category, text: String, source: Source, updatedAt: Date) {
        self.id = id
        self.category = category
        self.text = text
        self.source = source
        self.updatedAt = updatedAt
    }

    /// The same limits the server holds the coach to (`server/profile.py`).
    public static let textLimit = 300
    public static let entryLimit = 60
}

/// A change the coach made to the profile during one reply.
///
/// **Validated again on the phone before it's written** — the rules are the
/// server's, but the phone doesn't trust a change because it came back from
/// its own server. A change that breaks one is skipped, not trimmed.
public struct CoachMemoryChange: Hashable, Sendable, Codable {
    public enum Operation: String, Sendable, Codable {
        case add, update, remove
    }

    public var op: Operation
    public var id: String
    public var category: String
    public var text: String

    public init(op: Operation, id: String, category: String, text: String) {
        self.op = op
        self.id = id
        self.category = category
        self.text = text
    }

    /// Whether this change may be applied at all.
    public var isValid: Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        if op == .remove { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoachMemoryEntry.Category(rawValue: category) != nil
            && !trimmed.isEmpty && trimmed.count <= CoachMemoryEntry.textLimit
    }

    /// What the transcript says under a reply: "Noted: …".
    public var summary: String {
        switch op {
        case .add: "Noted: \(text)"
        case .update: "Updated: \(text)"
        case .remove: "Forgot: \(text)"
        }
    }
}

/// A conversation with the coach (INFRA-SPEC §13.6).
public struct CoachConversation: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A conversation's title is its first message, shortened.
    public static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(57)) + "…"
    }
}

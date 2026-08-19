import Foundation
import LiftingCoachModel

/// Assembles a `DataExport` from the local database.
///
/// Lives beside the stores rather than in the app target because it's a read
/// over persistence, and because phase 2's sync will want exactly this — one
/// place that knows how to say "everything, as values" — rather than a second
/// traversal written against the same tables.
///
/// **Deliberately not paged or streamed.** Export is a single explicit action
/// on a phone holding one lifter's history, and correctness beats cleverness:
/// `WorkoutStore.fetch(from:to:)` hydrates every set of every workout, which is
/// the expensive path and also the only one that produces a complete archive.
/// Against the owner's real log (840 workouts, 14,520 sets) that's thousands of
/// queries, so callers run it off the main actor and show that it's working.
/// If this ever needs to be fast, the fix is bulk queries here — not a thinner
/// archive.
public struct DataExporter: Sendable {
    private let database: AppDatabase
    private let calendar: Calendar

    public init(_ database: AppDatabase, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
    }

    /// Everything held for one lifter.
    public func export(for userId: UUID, at date: Date = Date()) throws -> DataExport {
        let users = UserStore(database, calendar: calendar)
        guard let user = try users.fetch(id: userId) else {
            throw ExportError.noSuchUser
        }

        // Unbounded on purpose — "from the beginning to whenever the last set
        // was logged" is the whole archive, and a window would silently clip it.
        let workouts = try WorkoutStore(database, calendar: calendar)
            .fetch(from: .distantPast, to: .distantFuture)
        let plan = try PlanStore(database, calendar: calendar).fetchPlan(userId: userId)

        return DataExport(exportedAt: date, user: user, workouts: workouts, plan: plan)
    }

    /// The archive as JSON bytes, ready to write.
    ///
    /// ISO 8601 dates and sorted keys: an archive is read by people and diffed
    /// by tools at least as often as it's parsed, and neither is served by
    /// `Date`'s default seconds-since-2001 double.
    ///
    /// One shape to know about: `WorkoutBlock.program` and `User.bodyWeight` are
    /// dictionaries keyed by `Date`, and JSON has no non-string keys, so those
    /// encode as flat alternating key/value arrays. That's `JSONEncoder`'s
    /// standard behaviour and it decodes back correctly; it just doesn't read
    /// as prettily as the rest of the file.
    public func exportJSON(for userId: UUID, at date: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export(for: userId, at: date))
    }

    public enum ExportError: Error, Equatable {
        /// Asked to export a lifter the database doesn't have.
        case noSuchUser
    }
}

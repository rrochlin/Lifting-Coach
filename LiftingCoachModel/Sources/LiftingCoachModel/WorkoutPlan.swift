import Foundation

/// The umbrella for all of a `User`'s programming — a sequence of
/// `WorkoutBlock`s over time. Starting a new training block means appending a
/// new block here, not creating a new plan.
public struct WorkoutPlan: Codable, Hashable, Sendable {
    public var blocks: [WorkoutBlock]?

    public init(blocks: [WorkoutBlock]? = nil) {
        self.blocks = blocks
    }

    /// Blocks sorted by `startDate`, oldest first. Blocks without a `startDate`
    /// aren't schedulable and are dropped from the ordering.
    public var scheduledBlocks: [WorkoutBlock] {
        (blocks ?? [])
            .filter { $0.startDate != nil }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    /// The last block whose `startDate` is on or before `date`.
    ///
    /// Derived rather than stored, so there's no second copy of the fact to go
    /// stale. This deliberately ignores `endDate`: a block whose planned end has
    /// passed (slipped schedule, an unlogged deload week) stays current until the
    /// *next* block's `startDate` actually arrives, so nothing disappears from
    /// view on the block's last day.
    public func currentBlock(asOf date: Date = Date(), calendar: Calendar = .current) -> WorkoutBlock? {
        let today = calendar.startOfDay(for: date)
        return scheduledBlocks.last { block in
            calendar.startOfDay(for: block.startDate ?? .distantPast) <= today
        }
    }

    /// The block immediately after `currentBlock` in schedule order, whether or
    /// not it has started — surfaced during deload so the user can preview what
    /// they're training toward next.
    public func nextBlock(asOf date: Date = Date(), calendar: Calendar = .current) -> WorkoutBlock? {
        let ordered = scheduledBlocks
        guard let current = currentBlock(asOf: date, calendar: calendar) else {
            // Nothing has started yet — the whole plan is still ahead.
            return ordered.first
        }
        guard let index = ordered.firstIndex(where: { $0.id == current.id }) else { return nil }
        let next = ordered.index(after: index)
        return next < ordered.endIndex ? ordered[next] : nil
    }
}

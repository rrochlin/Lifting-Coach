import Foundation

/// What the lifter did last time, offered for a set that has nothing in it.
///
/// A **proposal**, and the distinction matters. The app never adjusts a
/// prescription (Core Tenets §1), and this doesn't: it only ever fills a field
/// that is empty because nothing was prescribed there — an ad-hoc exercise, a
/// set added mid-workout, a warmup, a drop, or a percentage that couldn't
/// resolve against a max the lifter hasn't recorded. Where the program said
/// something, `WorkoutSession.start(from:)` has already written it as a real
/// value and this never sees the field.
///
/// Pure and separate from the view so the matching rules below are testable,
/// which they need to be — "which of last session's sets corresponds to this
/// one" has more edge cases than it looks like it does.
public enum SetSuggestion {

    /// Reps and weight from the matching set of a previous session.
    public struct Values: Hashable, Sendable {
        public var reps: Int?
        public var weight: Measurement<UnitMass>?

        public init(reps: Int? = nil, weight: Measurement<UnitMass>? = nil) {
            self.reps = reps
            self.weight = weight
        }

        /// Nothing worth showing. A suggestion with neither number is not an
        /// honest empty state, it's just an empty one (Core Tenets §10).
        public var isEmpty: Bool { reps == nil && weight == nil }
    }

    /// The suggestion for the set at `index` within `current`, drawn from
    /// `previous` — the same exercise's most recent completed session.
    ///
    /// Matching is **within set type**, by position among sets of that type:
    /// the second working set of today lines up with the second working set of
    /// last time. Type matters because the alternative is nonsense — a warmup
    /// matched against a top single suggests 405 for a ramp-up, and a drop set
    /// matched positionally against a working set suggests the weight it is
    /// specifically meant to be below.
    ///
    /// Where today has more sets of a type than last time did, the **last** set
    /// of that type carries over: a fifth working set most resembles the fourth,
    /// not the first.
    ///
    /// Returns nil when the set already has both numbers, when there's no
    /// history, or when the matched set has nothing to offer.
    public static func forSet(
        at index: Int,
        in current: [WorkoutSet],
        previous: [WorkoutSet]
    ) -> Values? {
        guard current.indices.contains(index) else { return nil }
        let set = current[index]
        // Nothing to propose for a set that's already been filled in — and
        // nothing to propose for one already logged, which is history now.
        guard set.complete != true else { return nil }
        guard set.reps == nil || set.weight == nil else { return nil }

        let type = set.type ?? .working
        // Where this set sits among its own kind, today.
        let ordinal = current[..<index].filter { ($0.type ?? .working) == type }.count

        let candidates = previous.filter { ($0.type ?? .working) == type && $0.complete == true }
        guard let match = candidates.indices.contains(ordinal)
            ? candidates[ordinal]
            : candidates.last
        else { return nil }

        // Only offered for what's actually missing — a set with reps typed and
        // no weight gets a weight, and keeps its reps.
        let values = Values(
            reps: set.reps == nil ? match.reps : nil,
            weight: set.weight == nil ? match.weight : nil
        )
        return values.isEmpty ? nil : values
    }
}

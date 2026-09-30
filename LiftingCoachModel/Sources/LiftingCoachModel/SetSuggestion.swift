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
    /// Where history has nothing to say, **the set above does**. A lifter who
    /// types 225 into the first working set and leaves four blank below has
    /// stated the weight for this exercise today as clearly as last week's log
    /// ever could — and on a lift with no history at all (a new exercise, a
    /// first session on a fresh install) last week's log says nothing.
    ///
    /// Strictly a fallback, and that ordering is deliberate. Last session
    /// matches *by ordinal within type*, so it knows a fourth working set is a
    /// back-off and that a warmup ramp ascends; carrying the set above down
    /// would flatten a 45/95/135/185 ramp into four 45s. History wins wherever
    /// it has an answer, and this fills the silence.
    ///
    /// Returns nil when the set already has both numbers, when nothing above or
    /// behind has anything to offer, or when the matched set is empty.
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
        let match = candidates.indices.contains(ordinal) ? candidates[ordinal] : candidates.last

        // The nearest set of the same kind above this one that actually has a
        // number — searched per field, because the row directly above is
        // usually blank too. Four empty rows under a typed 225 should all read
        // 225, not all read nothing because their immediate neighbour is empty.
        //
        // Not required to be complete: typing a weight is the statement, and
        // waiting for the checkbox would leave those rows blank at exactly the
        // moment the lifter is looking at them.
        let earlier = current[..<index].filter { ($0.type ?? .working) == type }
        let repsAbove = earlier.last { $0.reps != nil }?.reps
        let weightAbove = earlier.last { $0.weight != nil }?.weight

        // Only offered for what's actually missing — a set with reps typed and
        // no weight gets a weight, and keeps its reps.
        let values = Values(
            reps: set.reps == nil ? (match?.reps ?? repsAbove) : nil,
            weight: set.weight == nil ? (match?.weight ?? weightAbove) : nil
        )
        return values.isEmpty ? nil : values
    }
}

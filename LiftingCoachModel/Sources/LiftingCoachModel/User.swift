import Foundation

/// A max that was actually lifted — an event, not a setting. Verified,
/// date-stamped, and kept as history rather than overwritten: the progression
/// itself is data.
public struct AchievedMax: Codable, Hashable, Sendable {
    public var weight: Measurement<UnitMass>
    /// When it was lifted.
    public var date: Date
    public var notes: String?

    public init(weight: Measurement<UnitMass>, date: Date, notes: String? = nil) {
        self.weight = weight
        self.date = date
        self.notes = notes
    }
}

/// The max a program is written against — aspirational by construction, set
/// deliberately. Replacing it is a decision, so the date it was set is kept so a
/// stale goal is visible as stale.
public struct GoalMax: Codable, Hashable, Sendable {
    public var weight: Measurement<UnitMass>
    public var dateSet: Date?

    public init(weight: Measurement<UnitMass>, dateSet: Date? = nil) {
        self.weight = weight
        self.dateSet = dateSet
    }
}

/// The target of a `WorkoutPlan`. The plan is designed for the user, and the
/// user also carries the metrics tracked against their performance.
public struct User: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var email: String
    public var workoutPlan: WorkoutPlan?
    /// Keyed by `Exercise.id`. Append-only history, newest resolved by date.
    public var achievedMaxes: [Int: [AchievedMax]]?
    /// Keyed by `Exercise.id`. One per lift — setting a new goal replaces it.
    public var goalMaxes: [Int: GoalMax]?
    /// Keyed by start of day, same convention as `WorkoutBlock`'s dictionaries.
    public var bodyWeight: [Date: Measurement<UnitMass>]?

    public init(
        id: UUID = UUID(),
        name: String,
        email: String,
        workoutPlan: WorkoutPlan? = nil,
        achievedMaxes: [Int: [AchievedMax]]? = nil,
        goalMaxes: [Int: GoalMax]? = nil,
        bodyWeight: [Date: Measurement<UnitMass>]? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.workoutPlan = workoutPlan
        self.achievedMaxes = achievedMaxes
        self.goalMaxes = goalMaxes
        self.bodyWeight = bodyWeight
    }

    /// Most recently recorded bodyweight, if any.
    public var currentBodyWeight: Measurement<UnitMass>? {
        bodyWeight?.max { $0.key < $1.key }?.value
    }

    /// The most recent achieved max on record for an exercise, or `nil` if
    /// none has been logged. Exposed as the full event (not just the weight) so
    /// callers deciding whether a new set beats it — see `AchievedMaxUpdate` —
    /// don't need to reimplement "most recent by date".
    public func latestAchievedMax(for exerciseID: Int) -> AchievedMax? {
        achievedMaxes?[exerciseID]?.max { $0.date < $1.date }
    }

    /// The lifter's max for an exercise under a given reference:
    /// `.achieved` → the most recent achieved max; `.goal` → the goal;
    /// `.theoretical` → `nil` until the estimation model exists.
    public func max(_ reference: MaxReference, for exerciseID: Int) -> Measurement<UnitMass>? {
        switch reference {
        case .achieved:
            return latestAchievedMax(for: exerciseID)?.weight
        case .goal:
            return goalMaxes?[exerciseID]?.weight
        case .theoretical:
            // Derived from logged work, never entered or stored. Unresolvable
            // until that model exists — blank beats a guess (Core Tenets §10).
            return nil
        }
    }

    /// Resolves a `LoadPrescription` to a weight for a given exercise, or `nil`
    /// where the referenced max isn't recorded — not an error; the prescription
    /// displays as-is.
    public func resolvedWeight(
        for load: LoadPrescription,
        exercise: Exercise
    ) -> Measurement<UnitMass>? {
        load.resolvedWeight { self.max($0, for: exercise.id) }
    }
}

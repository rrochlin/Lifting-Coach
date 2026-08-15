import Foundation

/// The target of a `WorkoutPlan`. The plan is designed for the user, and the
/// user also carries the metrics tracked against their performance.
public struct User: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var email: String
    public var workoutPlan: WorkoutPlan?
    /// Keyed by `Exercise.id`.
    public var maxLifts: [Int: Measurement<UnitMass>]?
    /// Keyed by start of day, same convention as `WorkoutBlock`'s dictionaries.
    public var bodyWeight: [Date: Measurement<UnitMass>]?

    public init(
        id: UUID = UUID(),
        name: String,
        email: String,
        workoutPlan: WorkoutPlan? = nil,
        maxLifts: [Int: Measurement<UnitMass>]? = nil,
        bodyWeight: [Date: Measurement<UnitMass>]? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.workoutPlan = workoutPlan
        self.maxLifts = maxLifts
        self.bodyWeight = bodyWeight
    }

    /// Most recently recorded bodyweight, if any.
    public var currentBodyWeight: Measurement<UnitMass>? {
        bodyWeight?.max { $0.key < $1.key }?.value
    }

    /// Resolves a `LoadPrescription` to an absolute weight for a given exercise.
    ///
    /// `.percentOf1RM` needs a recorded max for that exercise and returns `nil`
    /// without one. `.rpe` intentionally returns `nil`: mapping RPE to a weight
    /// needs historical set data and a rep-range-aware model (see
    /// `Mid lift thoughts.md` — RPE on a triple and RPE on a set of 10 are not
    /// the same tool), so the tracker resolves it at log time, not here.
    public func resolvedWeight(
        for load: LoadPrescription,
        exercise: Exercise
    ) -> Measurement<UnitMass>? {
        switch load {
        case .absolute(let weight):
            return weight
        case .percentOf1RM(let percent):
            guard let max = maxLifts?[exercise.id] else { return nil }
            return Measurement(value: max.value * percent, unit: max.unit)
        case .rpe:
            return nil
        }
    }
}

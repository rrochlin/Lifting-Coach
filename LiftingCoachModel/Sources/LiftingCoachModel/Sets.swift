import Foundation

/// How a planned set's intensity is defined — resolved to an absolute weight
/// when the plan is turned into a live `Workout`.
public enum LoadPrescription: Codable, Hashable, Sendable {
    case absolute(Measurement<UnitMass>)
    case percentOf1RM(Double)
    case rpe(Float)

    /// Resolves to a concrete weight given the lifter's max for this exercise.
    ///
    /// Only `.percentOf1RM` actually needs `oneRepMax` — an absolute load
    /// resolves with no lifter data at all, which matters because a plan can be
    /// followed before any max has been recorded.
    ///
    /// `.rpe` deliberately returns `nil`: mapping an RPE target to a weight needs
    /// historical set data and a rep-range-aware model (per
    /// `Mid lift thoughts.md`, RPE on a triple and RPE on a set of 10 are not the
    /// same instrument), so the lifter supplies the number at log time.
    public func resolvedWeight(oneRepMax: Measurement<UnitMass>?) -> Measurement<UnitMass>? {
        switch self {
        case .absolute(let weight):
            return weight
        case .percentOf1RM(let percent):
            guard let oneRepMax else { return nil }
            return Measurement(value: oneRepMax.value * percent, unit: oneRepMax.unit)
        case .rpe:
            return nil
        }
    }
}

/// The prescription: what *should* be done. Distinct from `WorkoutSet`, which is
/// what was actually logged.
public struct PlannedSet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var reps: Int?
    public var type: SetType?
    public var load: LoadPrescription?
    /// Seconds. `nil` falls back to the containing `WorkoutBlock`'s
    /// `defaultRestTimes` for this `SetType`, then an app-level default — most
    /// sets shouldn't need this configured explicitly.
    public var restTime: Int?
    public var notes: String?

    public init(
        id: UUID = UUID(),
        reps: Int? = nil,
        type: SetType? = nil,
        load: LoadPrescription? = nil,
        restTime: Int? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.reps = reps
        self.type = type
        self.load = load
        self.restTime = restTime
        self.notes = notes
    }
}

/// What was actually logged during a workout.
public struct WorkoutSet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var reps: Int?
    public var weight: Measurement<UnitMass>?
    public var complete: Bool?
    public var type: SetType?
    public var timeComplete: Date?
    public var restTime: Int?
    public var rpe: Float?
    public var notes: String?
    public var usernotes: String?
    /// What this set was prescribed as, if any — lets planned vs. actual be
    /// reconciled without needing user context wherever a `WorkoutSet` is read.
    public var plannedFrom: PlannedSet?

    public init(
        id: UUID = UUID(),
        reps: Int? = nil,
        weight: Measurement<UnitMass>? = nil,
        complete: Bool? = nil,
        type: SetType? = nil,
        timeComplete: Date? = nil,
        restTime: Int? = nil,
        rpe: Float? = nil,
        notes: String? = nil,
        usernotes: String? = nil,
        plannedFrom: PlannedSet? = nil
    ) {
        self.id = id
        self.reps = reps
        self.weight = weight
        self.complete = complete
        self.type = type
        self.timeComplete = timeComplete
        self.restTime = restTime
        self.rpe = rpe
        self.notes = notes
        self.usernotes = usernotes
        self.plannedFrom = plannedFrom
    }
}

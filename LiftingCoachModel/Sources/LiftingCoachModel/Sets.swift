import Foundation

/// How a planned set's intensity is defined — resolved to an absolute weight
/// when the plan is turned into a live `Workout`.
public enum LoadPrescription: Codable, Hashable, Sendable {
    case absolute(Measurement<UnitMass>)
    case percentOf1RM(Double)
    case rpe(Float)
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

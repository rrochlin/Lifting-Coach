import Foundation

/// The prescription: what *should* be done. Distinct from `WorkoutSet`, which is
/// what was actually logged.
///
/// Load and effort are independent optional axes — either alone is a legitimate
/// prescription, not a gap to fill in (Core Tenets §2). A warmup usually carries
/// load with no effort target; an accessory can be "3×10 @ RPE 8, pick your
/// weight" with no load at all.
public struct PlannedSet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var reps: Int?
    public var type: SetType?
    /// What to put on the bar.
    public var load: LoadPrescription?
    /// Override for the odd set out (a top single, a back-off). `nil` means "use
    /// the containing `PlannedExercise`'s effort" — resolve with
    /// `set.effort ?? exercise.effort`, the same shape as `restTime`'s fallback.
    public var effort: EffortTarget?
    /// Seconds. `nil` falls back to the containing `WorkoutBlock`'s
    /// `defaultRestTimes` for this `SetType`, then an app-level default — most
    /// sets shouldn't need this configured explicitly.
    public var restTime: Int?
    /// Carries programming intent that has no structural home: "work up, stop at
    /// 9", "last set AMRAP", tempo, pauses.
    public var notes: String?

    public init(
        id: UUID = UUID(),
        reps: Int? = nil,
        type: SetType? = nil,
        load: LoadPrescription? = nil,
        effort: EffortTarget? = nil,
        restTime: Int? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.reps = reps
        self.type = type
        self.load = load
        self.effort = effort
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
    /// Legacy: rest actually taken, in seconds. **Nothing writes this any more.**
    ///
    /// It used to be derived as the gap between two completion timestamps, which
    /// overstates rest by however long the lifter took to pick the phone back up
    /// — a lag that never cancels out. Rows logged before that was removed still
    /// carry a value; the prescribed rest lives in `plannedFrom.restTime`, which
    /// is what the tracker displays. Kept as a column so existing history isn't
    /// destroyed (Design.md), not as a field to start writing again.
    public var restTime: Int?
    /// Rest the lifter set for *this* set, in seconds, overriding whatever the
    /// resolution chain would otherwise produce (`WorkoutSession.restTarget`).
    ///
    /// Deliberately a field of its own rather than a write into
    /// `plannedFrom.restTime`: the snapshot is what the plan asked for, and
    /// editing it in place would make a lifter's own 3:30 read back as though
    /// the program prescribed it. Planned and actual are never silently
    /// substituted (Core Tenets §6), and this is the "actual" side of rest.
    ///
    /// Also distinct from `restTime` above, which is legacy *measured* rest.
    /// This one is a chosen duration, not an observation.
    public var restOverride: Int?
    /// The unit this set is read and entered in, overriding the exercise's
    /// preference and the lifter's app-wide default. `nil` defers up the chain
    /// (`User.unit(forExerciseID:)`).
    ///
    /// A field of its own rather than reading `weight?.unit`, for two reasons.
    /// An empty set has no weight yet and still needs somewhere to say "I'm
    /// entering this one in kg." And this is a *reading* preference, not a
    /// restatement of what's stored — switching it converts what's on screen
    /// and rewrites nothing, exactly as `User.preferredUnit` does. 100 lb read
    /// in kg is 45.4 kg, the same iron; it is never reinterpreted as 100 kg.
    public var unit: WeightUnit?
    /// Achieved effort as the lifter rated it, per set — never defaulted from
    /// the prescription. Same 1–10 scale as `EffortTarget`.
    public var rpe: Float?
    public var notes: String?
    public var usernotes: String?
    /// What this set was prescribed as, if any — lets planned vs. actual be
    /// reconciled without needing user context wherever a `WorkoutSet` is read.
    /// The snapshot's `effort` is materialized (set-or-exercise resolved) at
    /// workout start, so history stays self-contained.
    public var plannedFrom: PlannedSet?

    public init(
        id: UUID = UUID(),
        reps: Int? = nil,
        weight: Measurement<UnitMass>? = nil,
        complete: Bool? = nil,
        type: SetType? = nil,
        timeComplete: Date? = nil,
        restTime: Int? = nil,
        restOverride: Int? = nil,
        unit: WeightUnit? = nil,
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
        self.restOverride = restOverride
        self.unit = unit
        self.rpe = rpe
        self.notes = notes
        self.usernotes = usernotes
        self.plannedFrom = plannedFrom
    }
}

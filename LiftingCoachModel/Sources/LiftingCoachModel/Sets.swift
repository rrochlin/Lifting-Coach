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
    /// How many identical sets this row prescribes — the "4" in "4×5 @ 225".
    ///
    /// A program is *written* as sets × reps × weight, and until this existed
    /// the planner made you author each of the four separately: four rows, four
    /// rep fields, four weights. A bulk "ALL 4 × 5 → APPLY" control was tried
    /// first and removed with this — it wrote the same prescription through a
    /// second control that had to be kept in agreement with the rows beneath
    /// it, which is the shape of every duplicated control this app has deleted.
    ///
    /// **A row is still one prescription, not a collapsed run.** Nothing
    /// re-groups sets by value: "5, 3, 5" stays three rows because that is
    /// three instructions, and `setGroups` (which collapses *consecutive*
    /// identical rows for display) is unchanged and still needed for programs
    /// written a row at a time. What this adds is the ability to say four sets
    /// once.
    ///
    /// Always at least 1 — a row prescribing zero sets is a row that should
    /// have been deleted, and the editor deletes rather than decrements to
    /// nothing. Clamped rather than validated, in `init` and on assignment, so
    /// no caller has to remember.
    ///
    /// **It expands at `WorkoutSession.start`**, one `WorkoutSet` per set, and
    /// the snapshot each logged set carries is normalized to `count: 1` — see
    /// the note there. Anything counting prescribed sets sums this rather than
    /// counting rows (`PlannedWorkout.plannedSetCount`).
    public var count: Int = 1 {
        didSet { if count < 1 { count = 1 } }
    }
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
        count: Int = 1,
        reps: Int? = nil,
        type: SetType? = nil,
        load: LoadPrescription? = nil,
        effort: EffortTarget? = nil,
        restTime: Int? = nil,
        notes: String? = nil
    ) {
        self.id = id
        // `didSet` doesn't fire during initialization, so the clamp is repeated
        // here rather than assumed.
        self.count = max(1, count)
        self.reps = reps
        self.type = type
        self.load = load
        self.effort = effort
        self.restTime = restTime
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, count, reps, type, load, effort, restTime, notes
    }

    /// Hand-written only to make `count` optional on the way in.
    ///
    /// A `PlannedSet` is encoded in two places that already hold years of data:
    /// every logged set's `plannedFrom` snapshot on disk, and any archive
    /// `DataExport` has written. Neither has a `count` key, and synthesized
    /// decoding of a non-optional `Int` would fail on all of them — which for
    /// `plannedFrom` means a workout that no longer loads. Absent means one,
    /// which is what those rows have always meant.
    ///
    /// `encode(to:)` stays synthesized; only reading is lenient.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.count = max(1, try container.decodeIfPresent(Int.self, forKey: .count) ?? 1)
        self.reps = try container.decodeIfPresent(Int.self, forKey: .reps)
        self.type = try container.decodeIfPresent(SetType.self, forKey: .type)
        self.load = try container.decodeIfPresent(LoadPrescription.self, forKey: .load)
        self.effort = try container.decodeIfPresent(EffortTarget.self, forKey: .effort)
        self.restTime = try container.decodeIfPresent(Int.self, forKey: .restTime)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// What was actually logged during a workout.
public struct WorkoutSet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var reps: Int?
    public var weight: Measurement<UnitMass>?
    public var complete: Bool?
    public var type: SetType?
    /// When this set was checked off, to the millisecond.
    ///
    /// **It is the tap, not the last rep.** The lifter racks the bar, breathes,
    /// picks the phone up and hits the checkbox, so this runs late by however
    /// long that took — a lag that never cancels out, and the same bias that
    /// got measured rest deleted from this app (see `restTime` below). Anything
    /// reading these as physiology has to carry that caveat with it; nothing
    /// here should quietly present one as the instant the set ended.
    ///
    /// **A set is stamped as an instant, not an interval.** There is no
    /// recorded start, so "when was this lifter working rather than resting"
    /// is not answerable from the log — it can only be *inferred* from
    /// consecutive completions, and that inference belongs to whatever does the
    /// analysis, not to storage. Recording a real start was considered and
    /// deliberately not built: the honest ways to get one are a per-set gesture
    /// mid-workout or an event written when the rest timer ends, and neither is
    /// worth its cost until something actually consumes the data.
    ///
    /// The point of keeping it precise anyway is correlation later — a heart
    /// rate series, or anything else on the same clock, lined up against the
    /// moment work stopped. That's why it's stored to the millisecond and why
    /// nothing rounds it.
    ///
    /// `nil` in two cases, both honest: a set that isn't complete, and the
    /// imported history — Strong's export carries no per-set times, so 14,520
    /// sets have none and never will. Any analysis has to tolerate that hole
    /// rather than filling it in.
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
    /// How long the set took, for work measured in time rather than reps — a
    /// plank, a bike interval, a walk.
    ///
    /// Distinct from every other duration on this type. `restTime` and
    /// `restOverride` are both about the gap *between* sets; this is the set
    /// itself. A set carrying a duration usually has no reps and no weight, and
    /// that's a complete record rather than a half-filled one.
    ///
    /// A `Measurement` for the same reason weights are: the unit travels with
    /// the number instead of living in a comment. Stored as seconds — there is
    /// no second unit to disambiguate, unlike distance.
    public var duration: Measurement<UnitDuration>?
    /// How far, for work measured in distance. Same shape and same reasoning as
    /// `duration`; the two usually appear together.
    public var distance: Measurement<UnitLength>?
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
        duration: Measurement<UnitDuration>? = nil,
        distance: Measurement<UnitLength>? = nil,
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
        self.duration = duration
        self.distance = distance
        self.rpe = rpe
        self.notes = notes
        self.usernotes = usernotes
        self.plannedFrom = plannedFrom
    }
}

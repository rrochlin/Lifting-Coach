import Foundation

/// Catalog entry for a specific lift/activity (bench press, deadlift) — the
/// reusable definition, not a specific instance of doing one. `id` is the key
/// used to index into workout history for historical trends, and is what
/// `User.achievedMaxes`/`goalMaxes` are keyed by.
///
/// `muscleGroup` is the one required, always-display field — every exercise in
/// this app has always had one. Everything below it is catalog metadata that
/// only entries sourced from an external database carry; a manually-created or
/// program-imported exercise (a top-level `Exercise(id:name:muscleGroup:)` call)
/// legitimately has all of it `nil`, and that's not a gap to fill in.
public struct Exercise: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var muscleGroup: String

    public var equipment: String?
    public var primaryMuscles: [String]?
    public var secondaryMuscles: [String]?
    public var instructions: [String]?
    /// beginner / intermediate / expert
    public var level: String?
    /// strength / cardio / stretching / powerlifting / etc.
    public var category: String?
    /// compound / isolation
    public var mechanic: String?
    /// push / pull / static
    public var force: String?
    /// The originating catalog's own identifier for this exercise (currently
    /// `yuhonas/free-exercise-db`'s slug, e.g. `"Barbell_Deadlift"`) — an
    /// **identity** claim: this row *is* that catalog entry. `nil` for
    /// exercises created directly rather than imported from a vendored catalog.
    /// Unique when present, so a re-import can upsert by it instead of
    /// duplicating rows.
    public var sourceSlug: String?

    /// This entry names a **goal or muscle group, not one specific movement**
    /// — "45 min LSS cardio," "pick a triceps exercise," "core work." A common
    /// and entirely legitimate way to program anything the coach isn't
    /// prescribing precisely: it makes no difference whether the cardio is a
    /// walk, a bike, or a stair climber, so nothing dictates one.
    ///
    /// Consequence: `AchievedMaxUpdate` must never treat a heavier weight
    /// logged under this exercise as a new max — a set of dumbbell
    /// extensions one week and cable pushdowns the next aren't the same lift,
    /// and comparing their weights would record a max that means nothing.
    ///
    /// **Authored, never inferred.** Whoever writes the program says which
    /// slots are open; nothing in the app reads a name and guesses. An earlier
    /// version derived this from a keyword matcher failing to find a movement
    /// word, which meant a correctly-programmed lift with an unusual name could
    /// silently become an open slot.
    public var isOpenChoice: Bool

    /// Movements the program floated for an open slot — "overhead extension,"
    /// "pushdown." Suggestions, not a whitelist: the lifter picks whatever they
    /// pick, and the app never refuses one (Core Tenets §1). Empty or `nil`
    /// wherever the program suggested nothing ("45 min cardio"), and meaningless
    /// on an exercise that isn't `isOpenChoice`.
    public var suggestions: [String]?

    public init(
        id: Int,
        name: String,
        muscleGroup: String,
        equipment: String? = nil,
        primaryMuscles: [String]? = nil,
        secondaryMuscles: [String]? = nil,
        instructions: [String]? = nil,
        level: String? = nil,
        category: String? = nil,
        mechanic: String? = nil,
        force: String? = nil,
        sourceSlug: String? = nil,
        isOpenChoice: Bool = false,
        suggestions: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.muscleGroup = muscleGroup
        self.equipment = equipment
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.instructions = instructions
        self.level = level
        self.category = category
        self.mechanic = mechanic
        self.force = force
        self.sourceSlug = sourceSlug
        self.isOpenChoice = isOpenChoice
        self.suggestions = suggestions
    }
}

/// How a set is being performed. Used both when prescribing (`PlannedSet`) and
/// when logging (`WorkoutSet`).
///
/// Deliberately does *not* include a `failure` case: per `Mid lift thoughts.md`,
/// failure is better expressed as RPE 10 plus forced partials or a weight drop,
/// and a sticky `failure` status on a set type caused real annoyance in Strong.
public enum SetType: String, Codable, Hashable, CaseIterable, Sendable {
    case warmup
    case working
    case drop
}

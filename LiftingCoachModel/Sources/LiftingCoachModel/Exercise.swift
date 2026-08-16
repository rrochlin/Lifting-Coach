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

    /// The catalog entry `CatalogMatcher` best-effort matched this exercise
    /// against to borrow its metadata — a **provenance** note, not an identity
    /// claim: this row did not become that exercise, and unlike `sourceSlug`
    /// this is not unique — "Bench press — heavy" and "Bench volume — Spoto
    /// press" can both, correctly, match the same canonical bench press entry.
    /// `nil` for a catalog-sourced row itself, or for one nothing matched.
    public var matchedSlug: String?

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
    /// `false` by default; set by `CatalogImporter` as a heuristic when
    /// `CatalogMatcher` finds no candidate sharing even one movement word with
    /// the name — a decent proxy (every real case behind this flag so far
    /// genuinely is an open slot), but a proxy, not a certainty. A oddly-named
    /// but still single, specific exercise could trip it too; the failure
    /// mode is a missed max update, not a corrupted one, which is the safe
    /// direction to be wrong in.
    public var isOpenChoice: Bool

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
        matchedSlug: String? = nil,
        isOpenChoice: Bool = false
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
        self.matchedSlug = matchedSlug
        self.isOpenChoice = isOpenChoice
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

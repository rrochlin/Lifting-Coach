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
        matchedSlug: String? = nil
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

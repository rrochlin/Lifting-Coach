import Foundation

/// Catalog entry for a specific lift/activity (bench press, deadlift) — the
/// reusable definition, not a specific instance of doing one. `id` is the key
/// used to index into workout history for historical trends, and is what
/// `User.maxLifts` is keyed by.
public struct Exercise: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var muscleGroup: String

    public init(id: Int, name: String, muscleGroup: String) {
        self.id = id
        self.name = name
        self.muscleGroup = muscleGroup
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

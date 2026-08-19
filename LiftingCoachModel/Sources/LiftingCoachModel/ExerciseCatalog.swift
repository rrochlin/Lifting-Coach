import Foundation

/// A minimal seed catalog so the app has something to program against before the
/// real catalog exists.
///
/// TODO: this is a placeholder. `Concepts.md` calls for a real catalog with
/// assets, muscle-group diagrams, and equipment type. Strong/Heavy appear to draw
/// from a shared free asset set — usable while the app stays internal, but it
/// must be swapped for properly licensed assets before any public release.
///
/// Scoped to the big three plus common accessories, matching the phase 1 goal of
/// supporting the owner's own training (bench/squat/deadlift).
public enum ExerciseCatalog {
    public static let seed: [Exercise] = [
        Exercise(id: 1, name: "Back Squat", muscleGroup: "Quads"),
        Exercise(id: 2, name: "Bench Press", muscleGroup: "Chest"),
        Exercise(id: 3, name: "Deadlift", muscleGroup: "Posterior Chain"),
        Exercise(id: 4, name: "Overhead Press", muscleGroup: "Shoulders"),
        Exercise(id: 5, name: "Barbell Row", muscleGroup: "Back"),
        Exercise(id: 6, name: "Incline Bench Press", muscleGroup: "Chest"),
        Exercise(id: 7, name: "Front Squat", muscleGroup: "Quads"),
        Exercise(id: 8, name: "Romanian Deadlift", muscleGroup: "Hamstrings"),
        Exercise(id: 9, name: "Pull Up", muscleGroup: "Back"),
        Exercise(id: 10, name: "Dip", muscleGroup: "Triceps"),
    ]
}

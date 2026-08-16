import Foundation

/// Decides whether a logged set is a new achieved max.
///
/// Achieved maxes come from sets, not from manual entry: log a heavier weight
/// than your current best and it *is* your new best — that's what "achieved"
/// means (Core Tenets §6). The comparison is on raw weight only. Reps are
/// deliberately not used to project a higher one-rep max (335×3 records an
/// achieved max of 335, not an estimate of what a single might have been) —
/// that kind of projection is `.theoretical`, a distinct and separately
/// unresolved concept.
///
/// Only `.working` sets are eligible. A warmup or drop set isn't a maximal
/// effort by definition, so a heavy warmup shouldn't overwrite a real max.
///
/// Also never eligible: an `Exercise` with `isOpenChoice` set. It names a goal
/// or muscle group, not one movement ("pick a triceps exercise," "45 min LSS
/// cardio") — a heavier weight logged under it this week than last doesn't
/// mean progress on the same lift, since it might not be the same lift at all.
public enum AchievedMaxUpdate {
    /// Returns the max to record if `set` beats `currentBest`, else `nil`.
    public static func evaluate(
        set: WorkoutSet,
        for exercise: Exercise,
        currentBest: AchievedMax?,
        at date: Date? = nil
    ) -> AchievedMax? {
        guard set.complete == true,
              set.type == .working,
              !exercise.isOpenChoice,
              let weight = set.weight
        else { return nil }

        if let currentBest, currentBest.weight >= weight { return nil }

        return AchievedMax(
            weight: weight,
            date: date ?? set.timeComplete ?? Date(),
            notes: set.reps.map { "\($0) rep\($0 == 1 ? "" : "s")" }
        )
    }
}

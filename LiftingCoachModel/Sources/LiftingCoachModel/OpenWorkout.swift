import Foundation

/// Whether a workout that's still open has gone quiet — the answer to "is the
/// lifter still training, or was this started by accident and forgotten?"
///
/// Pure, because the rule is the thing worth testing and three surfaces ask
/// it: the in-app prompt, the notification scheduled when the app goes to the
/// background, and the Home card that would otherwise start a second workout
/// over the top of a forgotten one (#32).
///
/// **Idle means no set has been checked off.** The last activity is the latest
/// `timeComplete` in the workout, or its start when nothing is logged yet. A
/// rest period, even a long one, ends in a completed set well inside the
/// threshold; typing into fields without completing anything for twenty
/// minutes is rare enough that a question costs less than a guess.
///
/// It only ever *asks*. Nothing here ends a workout: a forgotten session and a
/// very long one look the same from inside the log, and only the lifter knows
/// which this is (Core Tenets §1).
public enum OpenWorkout {
    /// Twenty minutes, the owner's number.
    public static let idleThreshold: TimeInterval = 20 * 60

    /// When the lifter last did something the log can see.
    public static func lastActivity(of workout: Workout) -> Date? {
        let completions = workout.allSets.compactMap(\.timeComplete)
        return ([workout.startTime].compactMap { $0 } + completions).max()
    }

    /// When this workout will have been idle long enough to ask about.
    ///
    /// `acknowledgedAt` is the lifter answering "still going" — the clock
    /// restarts from there, so the question isn't asked again a second later.
    public static func idleDeadline(
        of workout: Workout,
        acknowledgedAt: Date? = nil,
        threshold: TimeInterval = idleThreshold
    ) -> Date? {
        guard workout.endTime == nil,
              let last = lastActivity(of: workout) else { return nil }
        let reference = [last, acknowledgedAt].compactMap { $0 }.max() ?? last
        return reference.addingTimeInterval(threshold)
    }

    public static func isIdle(
        _ workout: Workout,
        at now: Date,
        acknowledgedAt: Date? = nil,
        threshold: TimeInterval = idleThreshold
    ) -> Bool {
        guard let deadline = idleDeadline(of: workout, acknowledgedAt: acknowledgedAt, threshold: threshold)
        else { return false }
        return now >= deadline
    }

    /// How many sets the lifter has checked off — what discarding would lose.
    public static func loggedSetCount(of workout: Workout) -> Int {
        workout.allSets.filter { $0.complete == true }.count
    }
}

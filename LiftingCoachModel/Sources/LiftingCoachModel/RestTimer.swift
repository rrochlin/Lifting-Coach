import Foundation

/// A rest period in progress.
///
/// Stores the *window* rather than a ticking count: a counter living in the
/// model would need saving, invalidating when the app is backgrounded, and
/// re-deriving on return — and the phone spends most of a rest period asleep in
/// a bag. Everything the timer displays is instead a function of the current
/// clock, so coming back to the app shows the truth with no catching up.
///
/// Not persisted. A rest period that spans an app relaunch has, in every case
/// that matters, already ended.
public struct RestTimer: Identifiable, Equatable, Sendable {
    /// Identifies this run of the timer, so a pending expiry can tell whether
    /// it still belongs to the rest period on screen.
    public let id = UUID()
    /// The exercise this rest follows. Lets the view render the timer directly
    /// beneath that lift instead of once, globally, at the top of the screen.
    public var exerciseID: UUID
    /// Named at the time it started, for the notification body — by the time
    /// that fires the lifter is looking at a banner, not the app.
    public var exerciseName: String
    public var startedAt: Date
    public var endsAt: Date
    /// Latched when the countdown reaches zero, so the view can announce it once
    /// (haptic) rather than on every tick afterwards.
    public var hasExpired = false

    public init(
        exerciseID: UUID,
        exerciseName: String,
        startedAt: Date,
        endsAt: Date
    ) {
        self.exerciseID = exerciseID
        self.exerciseName = exerciseName
        self.startedAt = startedAt
        self.endsAt = endsAt
    }

    /// Starts a rest period of the given length. A negative or zero length lands
    /// already finished rather than being rejected — "no rest prescribed here"
    /// is a legitimate thing for a plan to say.
    public init(exerciseID: UUID, exerciseName: String, seconds: Int, from date: Date) {
        self.init(
            exerciseID: exerciseID,
            exerciseName: exerciseName,
            startedAt: date,
            endsAt: date.addingTimeInterval(TimeInterval(max(0, seconds)))
        )
    }

    /// Extends or shortens the rest in progress — the ± buttons on the timer.
    ///
    /// Rest is a prescription the lifter is free to depart from (Core Tenets §1);
    /// adjusting the clock is them saying what they're doing, not the app
    /// deciding for them. Shortening below the time already elapsed lands on
    /// zero rather than going negative: "I'm going now" is the intent, and the
    /// timer should say so instead of counting up.
    ///
    /// Moving `endsAt` moves `progress`'s denominator with it, so the bar stays
    /// where the lifter left it instead of jumping on a ±30.
    public mutating func adjust(by seconds: Int, now: Date = Date()) {
        endsAt = max(now, endsAt.addingTimeInterval(TimeInterval(seconds)))
        hasExpired = isOver(at: now)
    }

    /// Floored at one second so `progress` can't divide by zero on a rest
    /// prescription of nothing.
    public var duration: TimeInterval { max(1, endsAt.timeIntervalSince(startedAt)) }

    /// Seconds left, floored at zero — the timer reports rest owed, and once
    /// none is owed there is nothing further to count.
    public func remaining(at date: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(date))
    }

    public func isOver(at date: Date) -> Bool { endsAt <= date }

    /// 0...1 elapsed, for the progress bar.
    public func progress(at date: Date) -> Double {
        min(1, max(0, 1 - remaining(at: date) / duration))
    }
}

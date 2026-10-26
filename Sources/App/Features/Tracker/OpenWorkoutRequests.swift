import Foundation
import UserNotifications

/// A request, from outside the Workout tab, to end the workout that's open.
///
/// Handed over the way `pendingStart` is, and for the same reason: the Workout
/// tab owns session state and there is exactly one owner. The idle prompt and
/// Home's "a workout is still open" question both end a session, so both say
/// *which* one and let the tracker do it. Carrying the id means a request that
/// arrives after the lifter has already moved on to a different workout does
/// nothing rather than ending the wrong one.
enum PendingWorkoutEnd: Equatable {
    /// End it at `at` — the last logged set, not the moment the question was
    /// answered, so a workout forgotten overnight doesn't read back as a
    /// fourteen-hour session.
    case finish(workoutID: UUID, at: Date)
    /// Throw it away. With sets logged, the tracker still asks first, naming
    /// how many it will delete; with none, there is nothing to ask about.
    case discard(workoutID: UUID)

    var workoutID: UUID {
        switch self {
        case .finish(let id, _), .discard(let id): id
        }
    }
}

/// The "still working out?" notification, for when the app isn't on screen to
/// ask (#32).
///
/// Scheduled when the app goes to the background with a workout open, for the
/// moment that workout will have been idle twenty minutes; cancelled whenever
/// the app comes back, because the in-app prompt asks from then on. Never
/// requests permission itself — the first rest period already asked, and a
/// lifter who declined has said what they think of notifications. Not
/// time-sensitive, unlike the rest alert: nobody is waiting under a bar.
@MainActor
enum OpenWorkoutNotifier {
    private static let identifier = "open-workout-idle"

    static func schedule(at deadline: Date, startedAt: Date?, now: Date = Date()) {
        let content = UNMutableNotificationContent()
        content.title = "Still working out?"
        if let startedAt {
            let time = startedAt.formatted(date: .omitted, time: .shortened)
            content.body = "Your workout from \(time) has had nothing logged for 20 minutes. Open the app to keep going or finish it."
        } else {
            content.body = "Your workout has had nothing logged for 20 minutes. Open the app to keep going or finish it."
        }
        content.sound = .default
        // Already past (the prompt was waiting on screen when the app left):
        // shortly after leaving rather than never.
        let interval = max(deadline.timeIntervalSince(now), 60)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            )
        )
    }

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

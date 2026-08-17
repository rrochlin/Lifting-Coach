import Foundation
import UserNotifications

/// Tells the lifter their rest is up when they aren't looking at the screen.
///
/// A rest timer is the one part of the tracker whose whole job happens while the
/// phone is face-down on the bench, so an in-app countdown alone can't do it. A
/// local notification is scheduled for the expiry instant and cancelled whenever
/// the rest period changes underneath it — extended, skipped, or ended by
/// finishing the workout.
///
/// Only ever one pending request (`identifier`): there's only one rest timer, and
/// re-scheduling with the same identifier replaces rather than stacks. Without
/// that, a lifter tapping +30 four times gets four alerts.
@MainActor
final class RestNotifier {
    /// Single fixed identifier — see the note above about replacement.
    private static let identifier = "rest-timer-expiry"

    /// `nil` until the first ask. Cached so a decline isn't re-asked every set.
    private var isAuthorized: Bool?

    /// Off for a notifier that must never prompt or post — the `-restDemo`
    /// screenshot path, where a permission alert would cover the very thing
    /// being photographed.
    private let isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    /// `UNUserNotificationCenter.current()` traps outside a real app bundle, so
    /// previews get no centre at all rather than a crash on the first set.
    private var center: UNUserNotificationCenter? {
        guard isEnabled,
              ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
        else { return nil }
        return .current()
    }

    /// Asks for permission the first time a rest period actually starts.
    ///
    /// Deliberately not at launch: a permission prompt before the lifter has
    /// seen what it's for is the kind of thing people decline reflexively, and
    /// there's no second chance in-app once they do.
    func requestAuthorizationIfNeeded() async {
        guard let center, isAuthorized == nil else { return }
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // A refused or unavailable notification centre isn't worth
            // interrupting a workout over — the on-screen timer still works.
            isAuthorized = false
        }
    }

    /// Schedules the expiry alert, replacing any pending one.
    ///
    /// A `date` already past schedules nothing and clears what's pending: the
    /// timer is over, and an alert about it would arrive as a lie.
    func schedule(at date: Date, exerciseName: String?, now: Date = Date()) {
        guard let center else { return }
        cancel()

        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = exerciseName.map { "Next set — \($0)" } ?? "Next set"
        content.sound = .default
        // Not `.timeSensitive`, which would let this break through a Focus: that
        // level needs the Time Sensitive Notifications capability, and adding an
        // entitlement is not free on the personal-team signing this app uses.
        // Worth revisiting if rest alerts get muted in practice.

        center.add(
            UNNotificationRequest(
                identifier: Self.identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            )
        )
    }

    /// Drops the pending alert, and any delivered one still sitting in
    /// Notification Centre — a "rest complete" banner from three sets ago is
    /// just clutter.
    func cancel() {
        guard let center else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    /// Lets the alert show while the app is on screen too.
    ///
    /// iOS suppresses notifications for a foreground app by default, which for
    /// this one is exactly backwards: "in the app" during a workout usually
    /// means the phone is face-down on a bench with the tracker open behind the
    /// lock screen, or the lifter is reading a different tab. Call once at
    /// launch — the delegate has to be installed before delivery, not at the
    /// moment rest starts.
    static func installForegroundPresentation() {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            return
        }
        UNUserNotificationCenter.current().delegate = foregroundPresenter
    }

    /// Held for the process lifetime: `UNUserNotificationCenter.delegate` is a
    /// weak reference, so a locally-created presenter would be gone before the
    /// first rest period ended.
    private static let foregroundPresenter = ForegroundPresenter()

    /// Stateless, hence safe to hand to whichever thread the notification
    /// centre calls back on.
    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }
}

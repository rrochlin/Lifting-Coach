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
    /// `upNext` is the lift the **next** set belongs to, not the one this rest
    /// followed. That distinction is the whole of a gym-floor report: finishing
    /// the last set of deadlifts announced "Next set — Deadlift" while the
    /// lifter was already walking to the squat rack. A notification is read
    /// alone, with no screen around it to correct it, so it has to name the
    /// thing it is actually a countdown toward. `nil` means there is no next
    /// set — the last set of the workout — and the alert says so rather than
    /// inventing one.
    func schedule(at date: Date, upNext: String?, now: Date = Date()) {
        guard let center else { return }
        cancel()

        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = upNext.map { "Up next — \($0)" } ?? "Last set done"
        // The same three beeps the in-app chime plays, so rest sounds like rest
        // whether or not the app is on screen — `.default` was a generic ding
        // indistinguishable from every other app's.
        //
        // **This still obeys the ring/silent switch**, and nothing here can
        // change that: notification sound is delivered by the system, so the
        // `.playback` trick that makes `RestChime` audible on a silenced phone
        // does not apply. Bypassing silent from the background needs Apple's
        // Critical Alerts entitlement, which is granted by application and for
        // a much narrower class of app than this. Worth knowing before anyone
        // "fixes" this again.
        content.sound = UNNotificationSound(named: UNNotificationSoundName("rest-complete.wav"))
        // Breaks through a Focus, and through the lock screen's summary. This is
        // the rare alert that earns it: rest ending is worthless a minute late,
        // the lifter is standing at the rack waiting for it, and a gym is
        // exactly where Do Not Disturb tends to be on. Backed by the Time
        // Sensitive Notifications entitlement in LiftingCoach.entitlements,
        // which needs the paid Developer Program — without it iOS silently
        // demotes this to `.active` rather than failing, so a build signed by a
        // personal team still works, just quietly.
        //
        // Nothing else in the app posts a notification, so there is no risk of
        // this level spreading to alerts that haven't earned it.
        content.interruptionLevel = .timeSensitive

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
            // Banner only. `RestChime` is already playing at this exact moment
            // and plays the same three beeps, so asking for `.sound` here would
            // double them — and the chime is the better of the two, because it
            // goes through the silent switch and this wouldn't.
            [.banner]
        }
    }
}

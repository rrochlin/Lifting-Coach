import Foundation
#if os(iOS)
import AVFoundation
import AudioToolbox
import UIKit
#endif

/// The sound rest makes when it's up.
///
/// The complaint was "no sound on rest completion", and the reason is worth
/// stating because it looked like it was already handled: the scheduled
/// `UNNotification` does carry `.sound`, but a notification is the wrong thing
/// to depend on here. It needs a permission the lifter may have declined, it's
/// the *fallback* for when the app isn't on screen, and a phone face-down on a
/// bench with the tracker open is the main case, not the edge one.
///
/// So this plays directly, and it plays **through the silent switch**. That's
/// the entire point of the `.playback` category: a gym is full of phones on
/// silent, and a rest timer nobody can hear is a rest timer that doesn't work.
///
/// It also refuses to stop the music. `.mixWithOthers` keeps whatever is
/// playing playing, and `.duckOthers` dips it for the length of the chime
/// instead of interrupting it — the lifter is listening to something, and an
/// app that pauses it every two minutes gets its sound turned off.
@MainActor
enum RestChime {
    #if os(iOS)
    /// A short system chime. Deliberately a system sound rather than a bundled
    /// asset: nothing has to ship, and it sounds like the phone rather than
    /// like an app being clever. Swap in a real asset here if it ever needs to
    /// be recognisable across a room.
    private static let soundID: SystemSoundID = 1005

    private static var didConfigureSession = false
    #endif

    /// Plays the chime and fires the haptic. Both, on purpose: the phone is
    /// often in a pocket or under a towel, and either channel alone misses.
    static func play() {
        #if os(iOS)
        configureSessionIfNeeded()
        AudioServicesPlaySystemSound(soundID)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    #if os(iOS)
    /// Configured once, and lazily — at the first rest period rather than at
    /// launch. Activating an audio session is a claim on the device's audio,
    /// and an app that makes it on startup shows up in the lifter's now-playing
    /// controls before it has made a sound.
    private static func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback, mode: .default, options: [.mixWithOthers, .duckOthers]
        )
        try? session.setActive(true)
    }
    #endif
}

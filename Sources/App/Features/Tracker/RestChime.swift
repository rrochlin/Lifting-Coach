import Foundation
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// The sound rest makes when it's up.
///
/// The original complaint was "no sound on rest completion", and the reason is
/// worth stating because it looked like it was already handled: the scheduled
/// `UNNotification` does carry `.sound`, but a notification is the wrong thing
/// to depend on here. It needs a permission the lifter may have declined, it's
/// the *fallback* for when the app isn't on screen, and a phone face-down on a
/// bench with the tracker open is the main case, not the edge one.
///
/// **The second complaint was that it still didn't work** — "I had it open and
/// the sound didn't fire, I did get a notification though", and separately
/// "sound is wayyyyy too quiet". Both were one bug. This played
/// `AudioServicesPlaySystemSound`, and a system sound is routed by the system
/// rather than through this app's `AVAudioSession`: the `.playback` category
/// that is supposed to make rest audible on a silenced phone had no bearing on
/// it, so on silent it was simply dropped, and its volume was never ours to
/// set. Playing a real asset through `AVAudioPlayer` is what actually honours
/// the category — and it's why the chime can be three rising beeps instead of
/// whatever sound 1005 happens to be. See `Tools/make-rest-chime.py`.
///
/// It still refuses to stop the music. `.mixWithOthers` keeps whatever is
/// playing playing, and `.duckOthers` dips it for the length of the chime
/// instead of interrupting it — the lifter is listening to something, and an
/// app that pauses it every two minutes gets its sound turned off.
///
/// **The session is deactivated once the chime finishes**, which the third
/// report is about: "my music audio was quiet until the timer got dismissed".
/// `.duckOthers` ducks for as long as the session is *active*, and this used to
/// activate once and never let go — so the first rest period of a workout dipped
/// the lifter's music for the rest of the session. Deactivating with
/// `.notifyOthersOnDeactivation` is what tells the music app to come back up.
@MainActor
enum RestChime {
    #if os(iOS)
    /// Held across plays: an `AVAudioPlayer` that goes out of scope stops
    /// mid-sound, and preparing the buffer once keeps the chime instant at the
    /// moment it has to be.
    private static var player: AVAudioPlayer?
    /// Cancels a pending deactivation when a second chime lands on top of the
    /// first, so the session isn't torn down underneath a sound still playing.
    private static var releaseTask: Task<Void, Never>?
    #endif

    /// Plays the chime and fires the haptic. Both, on purpose: the phone is
    /// often in a pocket or under a towel, and either channel alone misses.
    static func play() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard let player = preparedPlayer() else { return }
        releaseTask?.cancel()

        let session = AVAudioSession.sharedInstance()
        // Set every time rather than once: another part of iOS (or a phone call)
        // can leave the session on a different category, and a rest timer that
        // works only until something else touches the audio isn't a rest timer.
        try? session.setCategory(
            .playback, mode: .default, options: [.mixWithOthers, .duckOthers]
        )
        try? session.setActive(true)

        player.currentTime = 0
        player.play()

        // Hold the duck for the chime plus a moment, then hand the audio back.
        releaseTask = Task {
            try? await Task.sleep(for: .milliseconds(Int(player.duration * 1000) + 250))
            guard !Task.isCancelled else { return }
            try? AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation]
            )
        }
        #endif
    }

    #if os(iOS)
    /// Loaded lazily, at the first rest period rather than at launch —
    /// preparing a player is a claim on the device's audio, and an app that
    /// makes it on startup shows up in the lifter's now-playing controls before
    /// it has made a sound.
    private static func preparedPlayer() -> AVAudioPlayer? {
        if let player { return player }
        guard let url = Bundle.main.url(forResource: "rest-complete", withExtension: "wav"),
              let loaded = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        // Full scale. The asset carries its own headroom (see the generator);
        // attenuating here is how a chime ends up inaudible in a gym.
        loaded.volume = 1.0
        loaded.prepareToPlay()
        player = loaded
        return loaded
    }
    #endif
}

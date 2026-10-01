import SwiftUI
import UIKit
import LiftingCoachModel
import LiftingCoachPersistence

@main
struct LiftingCoachApp: App {
    @State private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // A failure here means the on-device database can't be opened or
        // migrated, which the app can't meaningfully run without. Surfaced as a
        // crash deliberately while phase 1 is single-user and internal — revisit
        // with a real recovery path before anyone else installs this.
        do {
            // Advisory, sent as S3 object metadata so a log line can name the
            // handset. Per-vendor, so it identifies nothing outside this app.
            let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            _environment = State(initialValue: try AppEnvironment.live(deviceID: deviceID))
        } catch {
            fatalError("Could not open the workout database: \(error)")
        }

        // Has to be in place before any notification is delivered, so it can't
        // wait until a rest period starts.
        RestNotifier.installForegroundPresentation()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                // Dark-only for now. The palette in `Theme` is built for a deep
                // ground; a light variant needs its own accent work rather than
                // an inversion, so it's a deliberate later pass, not an omission.
                .preferredColorScheme(.dark)
                .tint(Theme.signal)
                .onChange(of: scenePhase) { _, phase in
                    // The safety net, not the main trigger. The screens that
                    // change something say so as it happens; this catches the
                    // session that ended without one of them firing, and it is
                    // free when nothing has changed — `SnapshotSync` checks its
                    // flag before it exports anything, which matters because
                    // backgrounding happens dozens of times a day.
                    guard phase == .background else { return }
                    // Backgrounding is when an upload is most likely to be cut
                    // off — the phone is headed for a pocket. Asking for the
                    // background-task allowance gives a megabyte over cellular
                    // time to land; without it the app is suspended within
                    // seconds and the safety net has a hole in it.
                    let app = UIApplication.shared
                    let task = app.beginBackgroundTask(withName: "snapshot-upload")
                    Task {
                        await environment.syncBeforeSuspending()
                        app.endBackgroundTask(task)
                    }
                }
        }
    }
}

import SwiftUI
import LiftingCoachModel
import LiftingCoachPersistence

@main
struct LiftingCoachApp: App {
    @State private var environment: AppEnvironment

    init() {
        // A failure here means the on-device database can't be opened or
        // migrated, which the app can't meaningfully run without. Surfaced as a
        // crash deliberately while phase 1 is single-user and internal — revisit
        // with a real recovery path before anyone else installs this.
        do {
            _environment = State(initialValue: try AppEnvironment.live())
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
        }
    }
}

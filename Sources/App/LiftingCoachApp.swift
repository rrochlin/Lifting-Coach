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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }
}

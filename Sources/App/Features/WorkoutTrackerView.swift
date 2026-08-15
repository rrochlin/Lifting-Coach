import SwiftUI

/// The heart of the app — real-time set logging during a workout.
///
/// `Roadmap.md` names this as the first thing to build in phase 1: it's
/// fundamentally device-local and needs nothing from the backend.
struct WorkoutTrackerView: View {
    var body: some View {
        NavigationStack {
            ScaffoldNotice(
                feature: "Workout Tracker",
                doc: "Features/Workout Tracker.md",
                requirements: [
                    "See the currently planned workout",
                    "Check off sets as they're completed",
                    "Highlight the active exercise",
                    "Reorder exercises by drag",
                    "Add and delete sets and exercises mid-workout",
                    "Rest timer starts when a set is logged",
                    "Log notes and RPE per set and exercise",
                ]
            )
            .navigationTitle("Workout")
        }
    }
}

#Preview {
    WorkoutTrackerView()
        .environment(AppEnvironment.preview())
}

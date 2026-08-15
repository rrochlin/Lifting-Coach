import SwiftUI

/// One training block at a time, viewable and editable.
///
/// Phase 1 is manual authoring only — `Roadmap.md` defers AI plan generation and
/// live adjustment to phase 2, and `Features/Workout Planner.md` splits its own
/// requirements along the same line.
struct WorkoutPlannerView: View {
    var body: some View {
        NavigationStack {
            ScaffoldNotice(
                feature: "Workout Planner",
                doc: "Features/Workout Planner.md",
                requirements: [
                    "Show one workout block at a time",
                    "See programmed workouts, weights, and effort levels",
                    "Edit programmed lifts",
                    "Compact view that uses the full screen",
                    "Default focus on the current point in the block",
                ]
            )
            .navigationTitle("Plan")
        }
    }
}

#Preview {
    WorkoutPlannerView()
        .environment(AppEnvironment.preview())
}

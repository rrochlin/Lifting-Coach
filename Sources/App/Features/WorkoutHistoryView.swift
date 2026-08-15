import SwiftUI

/// Calendar view of logged workouts, per `Features/Workout History.md`.
struct WorkoutHistoryView: View {
    var body: some View {
        NavigationStack {
            ScaffoldNotice(
                feature: "Workout History",
                doc: "Features/Workout History.md",
                requirements: [
                    "Month-at-a-time calendar with dots for logged days",
                    "Tap a day for a summary overlay",
                    "Edit a past workout from the summary",
                ]
            )
            .navigationTitle("History")
        }
    }
}

#Preview {
    WorkoutHistoryView()
        .environment(AppEnvironment.preview())
}

import SwiftUI

/// Top-level navigation.
///
/// Tabs follow the feature docs in `notes/Workout App/Features/`. Coach
/// Conversation is deliberately absent: it's phase 2, and per its feature doc it
/// belongs as an overlay over whatever the user is already doing, not as a tab.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView()
            }
            Tab("Workout", systemImage: "figure.strengthtraining.traditional") {
                WorkoutTrackerView()
            }
            Tab("Plan", systemImage: "calendar.badge.clock") {
                WorkoutPlannerView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath") {
                WorkoutHistoryView()
            }
            Tab("Profile", systemImage: "person.crop.circle") {
                UserProfileView()
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
}

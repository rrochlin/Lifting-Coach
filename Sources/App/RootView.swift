import SwiftUI

/// Top-level navigation.
///
/// Tabs follow the feature docs in `notes/Workout App/Features/`. Coach
/// Conversation is deliberately absent: it's phase 2, and per its feature doc it
/// belongs as an overlay over whatever the user is already doing, not as a tab.
struct RootView: View {
    @State private var selection = RootTab.initialFromLaunchArguments

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                HomeView()
            }
            Tab("Workout", systemImage: "figure.strengthtraining.traditional", value: RootTab.workout) {
                WorkoutTrackerView()
            }
            Tab("Plan", systemImage: "calendar.badge.clock", value: RootTab.plan) {
                WorkoutPlannerView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: RootTab.history) {
                WorkoutHistoryView()
            }
            Tab("Profile", systemImage: "person.crop.circle", value: RootTab.profile) {
                UserProfileView()
            }
        }
    }
}

enum RootTab: String, Hashable, CaseIterable {
    case home, workout, plan, history, profile

    /// Lets a launch argument pick the starting tab: `-initialTab plan`.
    ///
    /// Exists because the simulator can be driven from the command line to
    /// install, launch, and screenshot, but not to tap — so without this there's
    /// no way to see any screen but Home outside of a UI test target. Harmless in
    /// a normal launch, where the argument simply isn't present.
    static var initialFromLaunchArguments: RootTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-initialTab"),
              case let next = arguments.index(after: index),
              next < arguments.endIndex,
              let tab = RootTab(rawValue: arguments[next])
        else { return .home }
        return tab
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
}

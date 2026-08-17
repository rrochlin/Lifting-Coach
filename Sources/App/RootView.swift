import SwiftUI

/// Top-level navigation.
///
/// Tabs follow the feature docs in `notes/Workout App/Features/`. Coach
/// Conversation is deliberately absent: it's phase 2, and per its feature doc it
/// belongs as an overlay over whatever the user is already doing, not as a tab.
struct RootView: View {
    @State private var selection = RootTab.initialFromLaunchArguments

    var body: some View {
        tabs
            .tint(Theme.signal)
            .onAppear {
                // The tab bar is the one surface UIKit still paints, and its
                // default material reads as a light-grey slab against the void.
                let appearance = UITabBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor(Theme.panel)
                appearance.shadowColor = UIColor(Theme.hairline)
                UITabBar.appearance().standardAppearance = appearance
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
    }

    private var tabs: some View {
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
        guard let raw = LaunchArguments.value(for: "-initialTab"),
              let tab = RootTab(rawValue: raw)
        else { return .home }
        return tab
    }
}

/// Launch arguments that open a screen the command line otherwise can't reach.
///
/// Same reasoning as `-initialTab`: simctl installs, launches, and screenshots,
/// but never taps, so any screen behind an interaction is invisible to a build
/// check. These are inert in a normal launch. They're a stopgap for the missing
/// UI test target, not a feature.
enum LaunchArguments {
    static func value(for name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }

    /// `-openPlanDay 3` pushes the planner's day editor onto the 4th programmed
    /// day of the selected block (0-based, in calendar order).
    static var planDayIndex: Int? {
        value(for: "-openPlanDay").flatMap(Int.init)
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
}

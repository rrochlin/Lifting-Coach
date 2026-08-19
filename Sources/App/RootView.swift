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
                HomeView(onOpenWorkout: { selection = .workout })
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

    /// `-restDemo 90` starts a throwaway ad-hoc workout, logs its first set, and
    /// leaves the rest timer running for that many seconds — `0` lands straight
    /// on the expired state.
    ///
    /// The rest timer only exists on the far side of a tap, so this is the only
    /// way to see it without a UI test target. It writes a real workout, so it's
    /// `#if DEBUG` at the call site as well as opt-in here.
    static var restDemoSeconds: Int? {
        value(for: "-restDemo").flatMap(Int.init)
    }

    /// `-openExercisePicker` opens the tracker's exercise picker on launch, and
    /// `-openExercisePicker <name>` pushes straight through to the detail
    /// screen of the first exercise whose name contains that text.
    ///
    /// Both are two taps deep — the picker behind "Add Exercise", the detail
    /// behind a row — so neither is otherwise reachable from the command line.
    static var exercisePickerQuery: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-openExercisePicker") else { return nil }
        let next = arguments.index(after: index)
        // A bare flag opens the list; a following value that isn't itself a
        // flag names the exercise to push onto.
        guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else { return "" }
        return arguments[next]
    }

    /// `-openWorkoutDetail 0` pushes the detail screen of the nth most recent
    /// logged workout (0-based). Needs `-initialTab history` beside it — the
    /// flag is read where that tab is built.
    ///
    /// The detail screen is behind a row tap, so this is the only way to see it
    /// from the command line.
    static var workoutDetailIndex: Int? {
        value(for: "-openWorkoutDetail").flatMap(Int.init)
    }

    /// `-editWorkout` opens that detail screen straight into edit mode.
    ///
    /// Edit mode is behind a toolbar tap, which puts it in the same category as
    /// the picker and the rest editor: reachable by hand, invisible to simctl.
    /// Same family of stopgap as `-initialTab`, and it stops being needed the
    /// day there's a UI test target.
    static var opensWorkoutEditor: Bool {
        ProcessInfo.processInfo.arguments.contains("-editWorkout")
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
}

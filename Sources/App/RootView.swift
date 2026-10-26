import SwiftUI
import LiftingCoachModel

/// Top-level navigation.
///
/// Tabs follow the feature docs in `notes/Workout App/Features/`. **Coach is a
/// tab** (owner's call, 2026-10-13), and it took Profile's seat: iPhone shows
/// five tabs and folds a sixth into a "More" list, and Profile — settings,
/// visited rarely — moved to a button in Home's toolbar.
struct RootView: View {
    @State private var selection = RootTab.initialFromLaunchArguments
    /// A day Home asked to start, handed to the Workout tab to act on.
    ///
    /// Passed rather than started here because the Workout tab owns session
    /// state and there is exactly one owner. Cleared by the tracker once it has
    /// taken it, so switching tabs later can't start the same day twice.
    @State private var pendingStart: PlannedWorkout?
    /// A request to end the open workout, handed over the same way — see
    /// `PendingWorkoutEnd`.
    @State private var pendingEnd: PendingWorkoutEnd?
    /// The workout that's started and not ended, if any. Drives the Workout
    /// tab's LIVE badge and the idle question (#32): an accidental start used
    /// to be visible only on Home's card, and a forgotten one stayed open
    /// indefinitely.
    @State private var openWorkout: Workout?
    /// When the lifter last answered "keep going", per workout. In memory on
    /// purpose: after a relaunch the question may be asked once more, which is
    /// cheaper than a forgotten workout nobody is ever asked about.
    @State private var idleAcknowledged: [UUID: Date] = [:]
    @State private var isAskingIfIdle = false
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        tabs
            .tint(Theme.signal)
            .task { await environment.refreshCloud() }
            // Once a minute is plenty for a twenty-minute question, and the
            // tracker reports its own changes in between (`onSessionChanged`).
            .task {
                while !Task.isCancelled {
                    refreshOpenWorkout()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .onChange(of: selection) { _, _ in refreshOpenWorkout() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    // Back on screen, so the in-app prompt does the asking.
                    OpenWorkoutNotifier.cancel()
                    refreshOpenWorkout()
                case .background:
                    scheduleIdleNotification()
                default:
                    break
                }
            }
            .themedChoice(
                isPresented: $isAskingIfIdle,
                title: "Still working out?",
                message: openWorkout.map(idleMessage),
                choices: idleChoices,
                dismissLabel: "Keep Going",
                onDismiss: acknowledgeIdle
            )
            .fullScreenCover(isPresented: signInPromptShown) { SignInPrompt() }
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

    /// Lapsed-session prompts dismissed this launch. A lapse asks once per
    /// launch and then gets out of the way — see `sessionLapsed`.
    @State private var lapsePromptDismissed = false

    /// Driven by the environment rather than a local flag, so it closes on its
    /// own the moment a sign-in lands. Suppressed when a DEBUG launch argument
    /// picked a tab: those runs are for screenshotting a screen, and a sheet
    /// over it would make every one of them a picture of this prompt.
    private var signInPromptShown: Binding<Bool> {
        Binding(
            get: {
                guard LaunchArguments.value(for: "-initialTab") == nil else { return false }
                return environment.requiresSignIn
                    || (environment.sessionLapsed && !lapsePromptDismissed)
            },
            set: { shown in if !shown { lapsePromptDismissed = true } }
        )
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                HomeView(
                    opensProfileAtLaunch: RootTab.launchedIntoProfile,
                    onStartWorkout: { planned in
                        pendingStart = planned
                        selection = .workout
                    },
                    // Resuming hands over nothing: the session is already on
                    // disk and the tracker picks it up itself.
                    onResumeWorkout: { selection = .workout },
                    // Home asked first, so both requests go together; the
                    // tracker ends the old workout before starting the new one.
                    onReplaceWorkout: { planned, end in
                        pendingEnd = end
                        pendingStart = planned
                        selection = .workout
                    }
                )
            }
            Tab("Workout", systemImage: "figure.strengthtraining.traditional", value: RootTab.workout) {
                WorkoutTrackerView(
                    pendingStart: $pendingStart,
                    pendingEnd: $pendingEnd,
                    onSessionChanged: refreshOpenWorkout
                )
            }
            // A workout is open. The tab is where it lives, so the tab says so
            // from anywhere in the app.
            .badge(openWorkout == nil ? nil : Text("LIVE"))
            Tab("Plan", systemImage: "calendar.badge.clock", value: RootTab.plan) {
                WorkoutPlannerView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: RootTab.history) {
                WorkoutHistoryView()
            }
            Tab("Coach", systemImage: "bubble.left.and.text.bubble.right", value: RootTab.coach) {
                CoachView()
            }
            // Replies that landed while you were elsewhere.
            .badge(environment.coach.unread)
        }
    }
}

// MARK: - The open workout

extension RootView {
    private func refreshOpenWorkout() {
        openWorkout = try? environment.workouts.fetchInProgress()
        guard let workout = openWorkout else {
            isAskingIfIdle = false
            return
        }
        // Not over a DEBUG screenshot run: `-initialTab` launches are for
        // looking at a screen, as with the sign-in prompt above.
        guard LaunchArguments.value(for: "-initialTab") == nil else { return }
        if OpenWorkout.isIdle(workout, at: Date(), acknowledgedAt: idleAcknowledged[workout.id]) {
            isAskingIfIdle = true
        }
    }

    private func acknowledgeIdle() {
        guard let workout = openWorkout else { return }
        idleAcknowledged[workout.id] = Date()
    }

    private func idleMessage(_ workout: Workout) -> String {
        let name = workout.notes ?? "This workout"
        let logged = OpenWorkout.loggedSetCount(of: workout)
        guard logged > 0, let last = OpenWorkout.lastActivity(of: workout) else {
            let started = workout.startTime.map { " at \(Self.clock($0))" } ?? ""
            return "\(name) was started\(started) and nothing has been logged."
        }
        return "\(name) has \(logged) set\(logged == 1 ? "" : "s") logged, the last at \(Self.clock(last))."
    }

    /// Finish ends it at the last logged set rather than now, and says so on
    /// the button: a workout forgotten overnight must not read back as an
    /// eleven-hour session. Offered only with something logged — finishing an
    /// empty workout records nothing worth keeping.
    private var idleChoices: [ThemedChoiceDialog.Choice] {
        guard let workout = openWorkout else { return [] }
        var choices: [ThemedChoiceDialog.Choice] = []
        if OpenWorkout.loggedSetCount(of: workout) > 0,
           let last = OpenWorkout.lastActivity(of: workout) {
            choices.append(.init(label: "Finish at \(Self.clock(last))") {
                pendingEnd = .finish(workoutID: workout.id, at: last)
                selection = .workout
            })
        }
        choices.append(.init(label: "Discard", role: .destructive) {
            // An answer, even if the tracker's own confirm is then cancelled —
            // otherwise this would be back a minute later.
            idleAcknowledged[workout.id] = Date()
            pendingEnd = .discard(workoutID: workout.id)
            selection = .workout
        })
        return choices
    }

    private func scheduleIdleNotification() {
        guard let workout = try? environment.workouts.fetchInProgress(),
              let deadline = OpenWorkout.idleDeadline(
                of: workout, acknowledgedAt: idleAcknowledged[workout.id])
        else { return }
        OpenWorkoutNotifier.schedule(at: deadline, startedAt: workout.startTime)
    }

    /// "6:42 PM" today, "Tue 6:42 PM" otherwise — a forgotten workout is
    /// usually from another day, and the day is the part that explains it.
    static func clock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

enum RootTab: String, Hashable, CaseIterable {
    case home, workout, plan, history, coach

    /// `-initialTab profile` still works: Profile is a sheet over Home now,
    /// so it opens Home and presents it. Every DEBUG flag that names the
    /// profile tab (`-openExerciseLibrary`, …) keeps working unchanged.
    static var launchedIntoProfile: Bool {
        LaunchArguments.value(for: "-initialTab") == "profile"
    }

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

    /// `-finishDemo` finishes the `-restDemo` workout the moment it's built,
    /// which is the only way to see `WorkoutSummaryOverlay` from the command
    /// line — it lives on the far side of a toolbar tap and a confirm dialog,
    /// and simctl can tap neither. Pair with `-restDemo`.
    static var finishesDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-finishDemo")
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

    /// `-searchExercises <query>` opens the picker with that already typed into
    /// the search field.
    ///
    /// Search is the one thing about the picker a screenshot can't otherwise
    /// reach: `simctl` can install, launch and screenshot, but it cannot type,
    /// so every ranked result was invisible from the command line. Same stopgap
    /// family as `-initialTab`, and it wants `-initialTab workout` beside it.
    static var exerciseSearchQuery: String? {
        value(for: "-searchExercises")
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

    /// `-openBlockSettings` opens the planner's block settings sheet. Needs
    /// `-initialTab plan` beside it, since it's read where that tab is built.
    ///
    /// Same family as the rest of these: the sheet is behind a tap on the
    /// block's header panel, and nothing on the command line can tap.
    static var opensBlockSettings: Bool {
        ProcessInfo.processInfo.arguments.contains("-openBlockSettings")
    }

    /// `-reorderMode` puts the tracker's list straight into reorder mode.
    /// Pair it with `-restDemo`, which is what creates a workout to reorder.
    ///
    /// Reorder mode is behind a tap in an exercise's `…` menu, so it's in the
    /// same family as the rest of these.
    static var opensReorderMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-reorderMode")
    }

    /// `-focusWeight` puts the keyboard on the next unlogged set's weight
    /// field, which is the only way to screenshot the numeric bar and what a
    /// field does on taking focus — `simctl` can't tap. Pair it with
    /// `-restDemo`.
    static var focusesWeightField: Bool {
        ProcessInfo.processInfo.arguments.contains("-focusWeight")
    }

    /// `-openExerciseLibrary` opens Profile's exercise library (needs
    /// `-initialTab profile`); `-openExerciseLibrary "Squat"` pushes straight
    /// through to that exercise's entry. Same stopgap family as the rest — the
    /// library is behind a tap, and simctl can't tap.
    static var opensExerciseLibrary: Bool {
        ProcessInfo.processInfo.arguments.contains("-openExerciseLibrary")
    }

    /// The exercise `-openExerciseLibrary` should open, if it names one.
    static var exerciseLibraryQuery: String? {
        value(for: "-openExerciseLibrary")
    }

    /// `-rpeDemo` opens the RPE scale on the first set row that draws one.
    ///
    /// The scale is a popover behind a tap, and simctl can't tap. It's also a
    /// control the owner has reported on twice from the gym, so being able to
    /// look at it from the command line is worth a flag — the first version of
    /// this check forced *every* `RPEPicker` on screen open at once, and iOS
    /// presented none of them.
    static var opensRPEScale: Bool {
        ProcessInfo.processInfo.arguments.contains("-rpeDemo")
    }

    /// `-openCalendarDay 18` opens History's calendar dialog on that day of the
    /// displayed month. Needs `-initialTab history`.
    ///
    /// The dialog is behind a tap on a grid cell, which is the one interaction
    /// `Features/Workout History.md` is most specific about and the one nothing
    /// on the command line can reach.
    static var calendarDay: Int? {
        value(for: "-openCalendarDay").flatMap(Int.init)
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

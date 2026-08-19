import SwiftUI
import LiftingCoachModel

/// Quick actions plus the headline metrics, per `Features/Homepage.md`.
///
/// Projected strength trend is still missing — it depends on the improved 1RM
/// projection work `Ideas.md` calls for, which needs a rep-range-aware model that
/// doesn't exist yet. It's marked low priority there, so it stays out rather than
/// shipping a number derived from the flawed formula the notes complain about.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Starts a programmed day and switches to the Workout tab.
    ///
    /// This used to only navigate, on the reasoning that starting writes a real
    /// in-progress workout and a stray tap on a home screen shouldn't. In
    /// practice the card is the one thing on Home a lifter deliberately reaches
    /// for, and landing on a screen that asks you to tap the same workout again
    /// is the app making you say it twice. Reversed on the owner's call.
    ///
    /// Home still doesn't own session state — it hands the planned day to the
    /// Workout tab, which starts it. And starting is not destructive: an
    /// in-progress workout is never clobbered, and DISCARD is one tap away.
    var onStartWorkout: (PlannedWorkout) -> Void = { _ in }

    @State private var plan = WorkoutPlan()
    @State private var todaysPlan: [PlannedWorkout] = []
    @State private var adherence: Adherence?
    @State private var loadError: String?
    @State private var isLoggingBodyWeight = false

    /// Squat / bench / deadlift, per Homepage.md — identified by their vendored
    /// catalog slugs rather than hardcoded ids. Maxes are recorded against the
    /// canonical catalog entry (a heavy Spoto press updates the bench max), so
    /// this has to look them up the same way to find anything.
    private let bigThreeSlugs = [
        "Barbell_Squat",
        "Barbell_Bench_Press_-_Medium_Grip",
        "Barbell_Deadlift",
    ]
    @State private var bigThree: [Exercise] = []

    var body: some View {
        NavigationStack {
            List {
                todaySection
                blockSection
                metricsSection
                vitalsSection
            }
            .listStyle(.plain)
            .screenGround()
            .navigationTitle("Lifting Coach")
            .refreshable { load() }
            .task { load() }
        }
        .sheet(isPresented: $isLoggingBodyWeight) {
            LogBodyWeightSheet(unit: environment.weightUnit) { weight in
                logBodyWeight(weight)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var todaySection: some View {
        SectionLabel(text: "today", accent: Theme.signal).panelRow()

        if todaysPlan.isEmpty {
            Panel {
                Text("Nothing programmed.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkMuted)
            }
            .panelRow()
        } else {
            ForEach(todaysPlan) { workout in
                Button { onStartWorkout(workout) } label: {
                    Panel(accent: Theme.signal.opacity(0.45)) {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 7) {
                                // The day's own name leads, with the lifts
                                // under it. Running the four exercise names
                                // together as the headline filled four lines
                                // and still didn't say which day this was.
                                Text(title(workout))
                                    .font(Theme.heading)
                                    .foregroundStyle(Theme.ink)
                                    .multilineTextAlignment(.leading)
                                Text(summary(workout))
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.inkMuted)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                Text("\(workout.allSets.count) SETS")
                                    .font(Theme.label)
                                    .tracking(1.4)
                                    .foregroundStyle(Theme.signal)
                            }
                            Spacer(minLength: 6)
                            // The card is the affordance now. It used to read
                            // "Open the Workout tab to start," which is an app
                            // asking to be navigated by hand.
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.signal)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .panelRow()
            }
        }
    }

    @ViewBuilder
    private var blockSection: some View {
        SectionLabel(text: "current block").panelRow()

        Panel {
            if let block = plan.currentBlock(), let progress = block.progress() {
                VStack(spacing: 9) {
                    Readout(
                        label: "week",
                        value: progress.totalWeeks.map { "\(progress.weekIndex) / \($0)" }
                            ?? "\(progress.weekIndex)",
                        accent: Theme.signal,
                        size: 17
                    )
                    Readout(label: "day", value: "\(progress.dayIndex)")
                    if let adherence, adherence.planned > 0 {
                        Readout(
                            label: "adherence",
                            value: "\(adherence.completed) / \(adherence.planned)"
                        )
                    }
                    if let notes = block.notes, !notes.isEmpty {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Text(notes)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("No training block scheduled.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .panelRow()
    }

    @ViewBuilder
    private var metricsSection: some View {
        // Achieved and goal are different data points and read as two columns —
        // never silently substituted for each other (Core Tenets §6).
        SectionLabel(text: "maxes · achieved / goal").panelRow()

        Panel {
            VStack(spacing: 9) {
                ForEach(bigThree) { exercise in
                    Readout(
                        label: exercise.name,
                        value: maxSummary(exercise.id),
                        accent: environment.currentUser?.max(.achieved, for: exercise.id) == nil
                            ? Theme.inkMuted : Theme.ink,
                        size: 17
                    )
                }
            }
        }
        .panelRow()

        if let loadError {
            Panel(accent: Theme.alert.opacity(0.5)) {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.alert)
            }
            .panelRow()
        }
    }

    /// Bodyweight is a separate concern from lift maxes: it's logged by
    /// explicit action, never inferred from a set. HealthKit metrics are named
    /// here rather than silently absent — `Backend/Overview.md` scopes them for
    /// phase 1, but the sync itself isn't wired up, and an honest "not
    /// connected" beats a missing section (Core Tenets §10).
    @ViewBuilder
    private var vitalsSection: some View {
        SectionLabel(text: "body").panelRow()

        Panel {
            VStack(spacing: 9) {
                Readout(
                    label: "bodyweight",
                    value: environment.currentUser?.currentBodyWeight?
                        .liftedDescription(in: environment.weightUnit) ?? "——",
                    accent: environment.currentUser?.currentBodyWeight == nil ? Theme.inkFaint : Theme.ink,
                    size: 17
                )
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Button { isLoggingBodyWeight = true } label: {
                    Label("Log Weight", systemImage: "plus")
                        .font(Theme.data(14, weight: .medium))
                        .foregroundStyle(Theme.signal)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .panelRow()

        SectionLabel(text: "health", accent: Theme.inkFaint).panelRow()

        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("NOT CONNECTED")
                    .font(Theme.label)
                    .tracking(1.4)
                    .foregroundStyle(Theme.inkFaint)
                Text("Heart rate, steps, and HRV sync via HealthKit isn't wired up yet.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .panelRow()
    }

    private func logBodyWeight(_ weight: Measurement<UnitMass>) {
        guard let user = environment.currentUser else { return }
        do {
            try environment.users.recordBodyWeight(weight, for: user.id)
            environment.reloadUser()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Data

    private func load() {
        guard let user = environment.currentUser else { return }
        do {
            plan = try environment.plans.fetchPlan(userId: user.id)
            todaysPlan = try environment.plans.fetchPlanned(on: Date())
            adherence = try currentAdherence()
            bigThree = try bigThreeSlugs.compactMap { try environment.exercises.fetch(sourceSlug: $0) }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Completed sets against programmed sets for the current block.
    ///
    /// Counts sets rather than workouts: a session cut short after two of five
    /// exercises is partial adherence, and workout-level counting would record it
    /// as full credit.
    private func currentAdherence() throws -> Adherence? {
        guard let block = plan.currentBlock() else { return nil }
        let hydrated = try environment.plans.attachingLoggedWorkouts(
            to: block,
            using: environment.workouts
        )

        let planned = (hydrated.program ?? [:]).values
            .flatMap { $0 }
            .reduce(0) { $0 + $1.allSets.count }
        let completed = (hydrated.workouts ?? [:]).values
            .flatMap { $0 }
            .reduce(0) { $0 + $1.allSets.filter { $0.complete == true }.count }

        return Adherence(completed: completed, planned: planned)
    }

    /// "achieved / goal", each blank where unrecorded — "— / 495 lb" is an
    /// honest state, not a display bug.
    private func maxSummary(_ id: Int) -> String {
        let unit = environment.weightUnit
        let achieved = environment.currentUser?.max(.achieved, for: id)?.liftedDescription(in: unit) ?? "—"
        let goal = environment.currentUser?.max(.goal, for: id)?.liftedDescription(in: unit) ?? "—"
        return "\(achieved) / \(goal)"
    }

    /// The program's name for the day, falling back to its lifts where a plan
    /// didn't label it.
    private func title(_ workout: PlannedWorkout) -> String {
        if let notes = workout.notes, !notes.isEmpty { return notes }
        return summary(workout)
    }

    private func summary(_ workout: PlannedWorkout) -> String {
        let names = (workout.exercises ?? []).flatMap { $0 }.map(\.displayName)
        return names.isEmpty ? "Empty workout" : names.joined(separator: ", ")
    }

    struct Adherence {
        var completed: Int
        var planned: Int
    }
}

// MARK: - Log bodyweight

private struct LogBodyWeightSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Opens on the lifter's own unit. The picker stays, because one weigh-in
    /// on a gym scale in the other unit shouldn't mean converting by hand.
    let unit: WeightUnit
    let onSave: (Measurement<UnitMass>) -> Void

    @State private var text = ""
    @State private var entryUnit: UnitMass = .pounds

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Weight", text: $text)
                        .keyboardType(.decimalPad)
                    Picker("Unit", selection: $entryUnit) {
                        Text("lb").tag(UnitMass.pounds)
                        Text("kg").tag(UnitMass.kilograms)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
            }
            .navigationTitle("Log Bodyweight")
            .onAppear { entryUnit = unit.unit }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value = Double(text) else { return }
                        onSave(Measurement(value: value, unit: entryUnit))
                        dismiss()
                    }
                    .disabled(Double(text) == nil)
                }
            }
        }
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment.preview())
}

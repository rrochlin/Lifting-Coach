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

    @State private var plan = WorkoutPlan()
    @State private var todaysPlan: [PlannedWorkout] = []
    @State private var adherence: Adherence?
    @State private var loadError: String?
    @State private var isLoggingBodyWeight = false

    private let bigThree = [1, 2, 3]  // squat, bench, deadlift — Homepage.md

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
            LogBodyWeightSheet { weight in
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
                Panel(accent: Theme.signal.opacity(0.45)) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(summary(workout))
                            .font(Theme.heading)
                            .foregroundStyle(Theme.ink)
                        Text("\(workout.allSets.count) SETS")
                            .font(Theme.label)
                            .tracking(1.4)
                            .foregroundStyle(Theme.signal)
                        // Starting happens on the Workout tab, which owns session
                        // state — duplicating the action here would give two paths
                        // into the same in-progress workout.
                        Text("Open the Workout tab to start.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkFaint)
                    }
                }
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
                ForEach(bigThree, id: \.self) { id in
                    Readout(
                        label: name(for: id),
                        value: maxSummary(id),
                        accent: environment.currentUser?.max(.achieved, for: id) == nil
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
                    value: environment.currentUser?.currentBodyWeight?.liftedDescription ?? "——",
                    accent: environment.currentUser?.currentBodyWeight == nil ? Theme.inkFaint : Theme.ink,
                    size: 17
                )
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Button { isLoggingBodyWeight = true } label: {
                    Label("Log Weight", systemImage: "plus")
                        .font(Theme.data(12, weight: .medium))
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
        let achieved = environment.currentUser?.max(.achieved, for: id)?.liftedDescription ?? "—"
        let goal = environment.currentUser?.max(.goal, for: id)?.liftedDescription ?? "—"
        return "\(achieved) / \(goal)"
    }

    private func name(for id: Int) -> String {
        ExerciseCatalog.seed.first { $0.id == id }?.name ?? "Exercise \(id)"
    }

    private func summary(_ workout: PlannedWorkout) -> String {
        let names = (workout.exercises ?? []).flatMap { $0 }.map(\.exercise.name)
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
    let onSave: (Measurement<UnitMass>) -> Void

    @State private var text = ""
    @State private var unit: UnitMass = .pounds

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Weight", text: $text)
                        .keyboardType(.decimalPad)
                    Picker("Unit", selection: $unit) {
                        Text("lb").tag(UnitMass.pounds)
                        Text("kg").tag(UnitMass.kilograms)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
            }
            .navigationTitle("Log Bodyweight")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value = Double(text) else { return }
                        onSave(Measurement(value: value, unit: unit))
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

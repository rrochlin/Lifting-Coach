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

    private let bigThree = [1, 2, 3]  // squat, bench, deadlift — Homepage.md

    var body: some View {
        NavigationStack {
            List {
                todaySection
                blockSection
                metricsSection
            }
            .navigationTitle("Lifting Coach")
            .refreshable { load() }
            .task { load() }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var todaySection: some View {
        Section("Today") {
            if todaysPlan.isEmpty {
                Text("Nothing programmed.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(todaysPlan) { workout in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary(workout)).font(.headline)
                        Text("\(workout.allSets.count) sets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Starting happens on the Workout tab, which owns session state —
                // duplicating the start action here would give two paths into the
                // same in-progress workout.
                Text("Open the Workout tab to start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var blockSection: some View {
        Section("Current Block") {
            if let block = plan.currentBlock(), let progress = block.progress() {
                LabeledContent("Week") {
                    if let total = progress.totalWeeks {
                        Text("\(progress.weekIndex) of \(total)")
                    } else {
                        Text("\(progress.weekIndex)")
                    }
                }
                LabeledContent("Day", value: "\(progress.dayIndex)")
                if let adherence, adherence.planned > 0 {
                    LabeledContent("Adherence") {
                        Text("\(adherence.completed)/\(adherence.planned) sets")
                            .monospacedDigit()
                    }
                }
                if let notes = block.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No training block scheduled.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        Section("Metrics") {
            ForEach(bigThree, id: \.self) { id in
                LabeledContent(name(for: id)) {
                    Text(maxLift(id)?.formatted(.measurement(width: .abbreviated, usage: .personWeight)) ?? "—")
                        .foregroundStyle(maxLift(id) == nil ? .secondary : .primary)
                }
            }
            LabeledContent("Bodyweight") {
                let weight = environment.currentUser?.currentBodyWeight
                Text(weight?.formatted(.measurement(width: .abbreviated, usage: .personWeight)) ?? "—")
                    .foregroundStyle(weight == nil ? .secondary : .primary)
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
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

    private func maxLift(_ id: Int) -> Measurement<UnitMass>? {
        environment.currentUser?.maxLifts?[id]
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

#Preview {
    HomeView()
        .environment(AppEnvironment.preview())
}

import SwiftUI
import LiftingCoachModel

/// The heart of the app — real-time set logging during a workout.
///
/// `Roadmap.md` names this as the first thing to build in phase 1: it's
/// fundamentally device-local and needs nothing from the backend.
struct WorkoutTrackerView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: TrackerModel?
    @State private var isPickingExercise = false
    @State private var isConfirmingFinish = false
    @State private var todaysPlan: [PlannedWorkout] = []

    var body: some View {
        NavigationStack {
            Group {
                if let model, model.isActive {
                    activeWorkout(model)
                } else {
                    idle
                }
            }
            .navigationTitle("Workout")
            .toolbar { toolbar }
        }
        .task {
            if model == nil {
                let model = TrackerModel(workouts: environment.workouts)
                model.resumeIfNeeded()
                self.model = model
            }
            todaysPlan = (try? environment.plans.fetchPlanned(on: Date())) ?? []
        }
        .sheet(isPresented: $isPickingExercise) {
            ExercisePicker { exercise in
                model?.addExercise(exercise, sets: 1)
            }
        }
    }

    // MARK: States

    @ViewBuilder
    private var idle: some View {
        if todaysPlan.isEmpty {
            ContentUnavailableView {
                Label("No workout in progress", systemImage: "figure.strengthtraining.traditional")
            } description: {
                Text("Nothing programmed for today. Start an empty session and add lifts as you go.")
            } actions: {
                Button("Start Empty Workout") { model?.startAdHoc() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                Section("Programmed Today") {
                    ForEach(todaysPlan) { planned in
                        Button {
                            start(planned)
                        } label: {
                            PlannedSummaryRow(workout: planned)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button("Start Empty Workout") { model?.startAdHoc() }
                }
            }
        }
    }

    /// Starts from the plan, handing over the block and lifter so `%1RM`
    /// prescriptions resolve to real weights and rest defaults apply.
    private func start(_ planned: PlannedWorkout) {
        let block = environment.currentUser
            .flatMap { try? environment.plans.fetchPlan(userId: $0.id) }
            .flatMap { plan in
                plan.scheduledBlocks.last { block in
                    block.program?.values.contains { $0.contains(where: { $0.id == planned.id }) } == true
                }
            }
        model?.start(from: planned, block: block, user: environment.currentUser)
    }

    private func activeWorkout(_ model: TrackerModel) -> some View {
        ActiveWorkoutList(
            model: model,
            onAddExercise: { isPickingExercise = true },
            onRequestFinish: { isConfirmingFinish = true }
        )
        .confirmationDialog(
            "Finish this workout?",
            isPresented: $isConfirmingFinish,
            titleVisibility: .visible
        ) {
            Button("Finish", role: .destructive) { model.finish() }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text(finishWarning(for: model))
        }
    }

    /// Say what's about to be dropped rather than letting it be discovered later.
    private func finishWarning(for model: TrackerModel) -> String {
        let progress = model.session?.progress ?? (completed: 0, total: 0)
        let skipped = progress.total - progress.completed
        guard skipped > 0 else { return "All sets are logged." }
        return "\(skipped) unfinished set\(skipped == 1 ? "" : "s") won't be saved."
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let model, model.isActive, let progress = model.session?.progress {
            // .navigation / .primaryAction rather than .topBarLeading /
            // .topBarTrailing: identical placement on iOS, but these also exist on
            // macOS, which keeps the sources typecheckable against the macOS SDK
            // while this machine's Xcode can't build for iOS at all.
            ToolbarItem(placement: .navigation) {
                Text("\(progress.completed)/\(progress.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Discard", role: .destructive) { model.discard() }
            }
        }
    }
}

// MARK: - Active workout list

/// Split out of `WorkoutTrackerView` because the whole list in one `body` blew
/// past the type-checker's budget — a single expression building sections,
/// nested `ForEach`es, and half a dozen closures is more than it will solve.
private struct ActiveWorkoutList: View {
    let model: TrackerModel
    let onAddExercise: () -> Void
    let onRequestFinish: () -> Void

    var body: some View {
        List {
            statusSection
            groupSections
            actionSection
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let message = model.saveError {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        if let restEndsAt = model.restEndsAt {
            Section {
                RestTimerRow(endsAt: restEndsAt) { model.dismissRest() }
            }
        }
    }

    @ViewBuilder
    private var groupSections: some View {
        let groups = model.session?.exerciseGroups ?? []
        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
            Section {
                ForEach(group) { exercise in
                    ExerciseSection(
                        exercise: exercise,
                        isActive: model.session?.activeExercise?.group == groupIndex,
                        onToggle: { toggle($0) },
                        onAddSet: { model.addSet(toExerciseWith: exercise.id) },
                        onDeleteSet: { model.deleteSet(id: $0) }
                    )
                }
            } header: {
                // A group of more than one exercise is a superset.
                if group.count > 1 {
                    Text("Superset")
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button("Add Exercise", systemImage: "plus", action: onAddExercise)
            Button("Finish Workout", systemImage: "checkmark.circle", action: onRequestFinish)
                .disabled(model.session?.progress.completed == 0)
        }
    }

    private func toggle(_ set: WorkoutSet) {
        if set.complete == true {
            model.uncompleteSet(id: set.id)
        } else {
            model.completeSet(id: set.id)
        }
    }
}

// MARK: - Planned summary

private struct PlannedSummaryRow: View {
    let workout: PlannedWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(names.isEmpty ? "Empty workout" : names.joined(separator: ", "))
                .font(.headline)
            Text("\(workout.allSets.count) sets")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let notes = workout.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var names: [String] {
        (workout.exercises ?? []).flatMap { $0 }.map(\.exercise.name)
    }
}

// MARK: - Exercise section

private struct ExerciseSection: View {
    let exercise: WorkoutExercise
    let isActive: Bool
    let onToggle: (WorkoutSet) -> Void
    let onAddSet: () -> Void
    let onDeleteSet: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(exercise.exercise.name)
                    .font(.headline)
                if isActive {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint, in: .capsule)
                        .foregroundStyle(.white)
                }
            }

            ForEach(Array((exercise.sets ?? []).enumerated()), id: \.element.id) { index, set in
                SetRow(number: index + 1, set: set) { onToggle(set) }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            onDeleteSet(set.id)
                        }
                    }
            }

            Button("Add Set", systemImage: "plus.circle") { onAddSet() }
                .font(.footnote)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Set row

private struct SetRow: View {
    let number: Int
    let set: WorkoutSet
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: set.complete == true ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(set.complete == true ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            // The primary interaction of the whole app — Workout Tracker.md's
            // "minimal effort" requirement — so give it a full-size hit target.
            .contentShape(.rect)

            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)

            Text(summary)
                .font(.subheadline.monospacedDigit())
                .strikethrough(set.complete == true, color: .secondary)

            Spacer()

            if let prescription {
                Text(prescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let reps = set.reps.map { "\($0)" } ?? "—"
        guard let weight = set.weight else { return "\(reps) reps" }
        return "\(reps) × \(weight.liftedDescription)"
    }

    /// The trailing label. Priority is what the lifter most needs to see:
    /// what they actually rated the set, then the target they were chasing, then
    /// a deviation from the prescribed reps.
    private var prescription: String? {
        let target: Float? = if case .rpe(let value) = set.plannedFrom?.load { value } else { nil }

        // A logged RPE is the whole point of logging RPE — show it whatever the
        // prescription was, not only when the set was prescribed by RPE.
        if let logged = set.rpe {
            guard let target else { return "RPE \(logged.rpeDescription)" }
            return "RPE \(logged.rpeDescription) / \(target.rpeDescription)"
        }
        if let target {
            return "RPE \(target.rpeDescription)"
        }
        if let plannedReps = set.plannedFrom?.reps, let actual = set.reps, plannedReps != actual {
            return "planned \(plannedReps)"
        }
        return nil
    }
}

// MARK: - Rest timer

private struct RestTimerRow: View {
    let endsAt: Date
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Label {
                // A live-updating countdown with no timer to manage by hand.
                Text(timerInterval: Date.now...endsAt, countsDown: true)
                    .monospacedDigit()
            } icon: {
                Image(systemName: "timer")
            }
            Spacer()
            Button("Skip", action: onDismiss)
                .font(.footnote)
        }
    }
}

// MARK: - Exercise picker

private struct ExercisePicker: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let onPick: (Exercise) -> Void

    @State private var exercises: [Exercise] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filtered) { exercise in
                Button {
                    onPick(exercise)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(exercise.name)
                        Text(exercise.muscleGroup)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query)
            .navigationTitle("Add Exercise")
            // iOS-only, and the app is iOS-only — the guard exists so these
            // sources still typecheck against the macOS SDK, which is currently
            // the only way to compile-check them on this machine.
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                exercises = (try? environment.exercises.fetchAll()) ?? []
            }
        }
    }

    private var filtered: [Exercise] {
        guard !query.isEmpty else { return exercises }
        return exercises.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

#Preview {
    WorkoutTrackerView()
        .environment(AppEnvironment.preview())
}

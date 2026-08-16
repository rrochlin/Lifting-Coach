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
        List {
            if todaysPlan.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NO SESSION")
                            .font(Theme.label)
                            .tracking(1.6)
                            .foregroundStyle(Theme.inkFaint)
                        Text("Nothing programmed for today.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.ink)
                    }
                }
                .panelRow()
            } else {
                SectionLabel(text: "programmed today", accent: Theme.signal)
                    .panelRow()
                ForEach(todaysPlan) { planned in
                    Button { start(planned) } label: {
                        PlannedSummaryRow(workout: planned)
                    }
                    .buttonStyle(.plain)
                    .panelRow()
                }
            }

            Button { model?.startAdHoc() } label: {
                Label("Start Empty Workout", systemImage: "plus")
                    .font(Theme.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
            .padding(.top, 6)
            .panelRow()
        }
        .listStyle(.plain)
        .screenGround()
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
                    .font(Theme.data(13, weight: .medium))
                    .foregroundStyle(progress.completed == progress.total ? Theme.signal : Theme.inkMuted)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("DISCARD", role: .destructive) { model.discard() }
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.alert)
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
        .listStyle(.plain)
        .screenGround()
    }

    @ViewBuilder
    private var statusSection: some View {
        if let message = model.saveError {
            Panel(accent: Theme.alert.opacity(0.5)) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.alert)
            }
            .panelRow()
        }
        if let restEndsAt = model.restEndsAt {
            RestTimerRow(endsAt: restEndsAt) { model.dismissRest() }
                .panelRow()
        }
    }

    @ViewBuilder
    private var groupSections: some View {
        let groups = model.session?.exerciseGroups ?? []
        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
            // A group of more than one exercise is a superset — marked with a
            // signal-coloured edge so the pairing reads without a header row.
            let isSuperset = group.count > 1
            VStack(spacing: 0) {
                if isSuperset {
                    SectionLabel(text: "superset", accent: Theme.signal)
                        .padding(.bottom, 8)
                }
                VStack(spacing: 10) {
                    ForEach(group) { exercise in
                        ExerciseSection(
                            exercise: exercise,
                            isActive: model.session?.activeExercise?.group == groupIndex,
                            onToggle: { toggle($0) },
                            onAddSet: { model.addSet(toExerciseWith: exercise.id) },
                            onDeleteSet: { model.deleteSet(id: $0) }
                        )
                    }
                }
                .padding(.leading, isSuperset ? 10 : 0)
                .overlay(alignment: .leading) {
                    if isSuperset {
                        Rectangle()
                            .fill(Theme.signalDim)
                            .frame(width: 2)
                    }
                }
            }
            .panelRow()
        }
    }

    private var actionSection: some View {
        VStack(spacing: 8) {
            Button(action: onAddExercise) {
                Label("Add Exercise", systemImage: "plus")
                    .font(Theme.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            }
            .foregroundStyle(Theme.ink)

            Button(action: onRequestFinish) {
                Label("Finish Workout", systemImage: "checkmark.circle")
                    .font(Theme.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(canFinish ? Theme.signalDim.opacity(0.28) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(canFinish ? Theme.signal : Theme.hairline, lineWidth: 1)
                    )
            }
            .foregroundStyle(canFinish ? Theme.signal : Theme.inkFaint)
            .disabled(!canFinish)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .panelRow()
    }

    private var canFinish: Bool {
        (model.session?.progress.completed ?? 0) > 0
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
        Panel(accent: Theme.signal.opacity(0.45)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(names.isEmpty ? "Empty workout" : names.joined(separator: " / "))
                        .font(Theme.heading)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.signal)
                }
                if let notes = workout.notes, !notes.isEmpty {
                    Text(notes)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                Text("\(workout.allSets.count) SETS")
                    .font(Theme.label)
                    .tracking(1.4)
                    .foregroundStyle(Theme.signal)
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
        Panel(accent: isActive ? Theme.live.opacity(0.55) : Theme.hairline) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(exercise.exercise.name)
                        .font(Theme.heading)
                        .foregroundStyle(Theme.ink)
                    if isActive {
                        Chip(text: "active", color: Theme.live)
                    }
                    Spacer()
                    Text(exercise.exercise.muscleGroup.uppercased())
                        .font(Theme.label)
                        .tracking(1.2)
                        .foregroundStyle(Theme.inkFaint)
                }

                Rectangle().fill(Theme.hairline).frame(height: 1)

                VStack(spacing: 2) {
                    ForEach(Array((exercise.sets ?? []).enumerated()), id: \.element.id) { index, set in
                        SetRow(number: index + 1, set: set) { onToggle(set) }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    onDeleteSet(set.id)
                                }
                            }
                    }
                }

                Button(action: onAddSet) {
                    Label("Add Set", systemImage: "plus")
                        .font(Theme.data(11, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Set row

private struct SetRow: View {
    let number: Int
    let set: WorkoutSet
    let onToggle: () -> Void

    var body: some View {
        let done = set.complete == true

        HStack(spacing: 10) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(done ? Theme.signal : Theme.hairline, lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(done ? Theme.signalDim.opacity(0.3) : Color.clear)
                        )
                        .frame(width: 22, height: 22)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.signal)
                    }
                }
                // The primary interaction of the whole app — Workout Tracker.md's
                // "minimal effort" requirement — so give it a full-size hit target.
                .frame(width: 40, height: 34)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Text(String(format: "%02d", number))
                .font(Theme.data(11))
                .foregroundStyle(Theme.inkFaint)

            Text(summary)
                .font(Theme.data(14, weight: done ? .regular : .medium))
                .foregroundStyle(done ? Theme.inkMuted : Theme.ink)

            Spacer(minLength: 8)

            if let prescription {
                Text(prescription)
                    .font(Theme.data(11))
                    .foregroundStyle(setTypeAccent)
            }
        }
        .padding(.vertical, 1)
    }

    /// Warmups read quieter than working sets — the HUD annotation layer
    /// carries set type without spending a column on it.
    private var setTypeAccent: Color {
        // `self.` is required: a bare `set` starting the body of a computed
        // property parses as the start of a setter declaration.
        self.set.type == .warmup ? Theme.inkFaint : Theme.inkMuted
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
        Panel(accent: Theme.live.opacity(0.55)) {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.live)
                Text("REST")
                    .font(Theme.label)
                    .tracking(1.6)
                    .foregroundStyle(Theme.live)
                // A live-updating countdown with no timer to manage by hand.
                Text(timerInterval: Date.now...endsAt, countsDown: true)
                    .font(Theme.data(20, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("SKIP", action: onDismiss)
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.inkMuted)
                    .buttonStyle(.plain)
            }
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

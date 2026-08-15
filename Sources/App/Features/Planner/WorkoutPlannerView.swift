import SwiftUI
import LiftingCoachModel

/// One training block at a time, viewable and editable.
///
/// Phase 1 is manual authoring only — `Roadmap.md` defers AI plan generation and
/// live adjustment to phase 2, and `Workout Planner.md` splits its own
/// requirements along the same line.
struct WorkoutPlannerView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: PlannerModel?
    @State private var isCreatingBlock = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Plan")
            .toolbar { toolbar }
        }
        .task { setUpIfNeeded() }
        .sheet(isPresented: $isCreatingBlock) {
            NewBlockSheet { start, weeks, notes in
                model?.createBlock(startDate: start, weeks: weeks, notes: notes)
            }
        }
    }

    private func setUpIfNeeded() {
        guard model == nil, let user = environment.currentUser else { return }
        let model = PlannerModel(plans: environment.plans, userID: user.id)
        model.load()
        self.model = model
    }

    @ViewBuilder
    private func content(_ model: PlannerModel) -> some View {
        if let block = model.selectedBlock {
            BlockDetail(model: model, block: block)
        } else {
            ContentUnavailableView {
                Label("No training block", systemImage: "calendar.badge.plus")
            } description: {
                Text("A block holds the workouts you're programming toward.")
            } actions: {
                Button("New Block") { isCreatingBlock = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Block", systemImage: "plus") { isCreatingBlock = true }
                if let model, !model.blocks.isEmpty {
                    Divider()
                    Picker("Block", selection: blockSelection) {
                        ForEach(model.blocks) { block in
                            Text(blockLabel(block)).tag(block.id)
                        }
                    }
                }
            } label: {
                Label("Blocks", systemImage: "ellipsis.circle")
            }
        }
    }

    private var blockSelection: Binding<UUID> {
        Binding(
            get: { model?.selectedBlockID ?? UUID() },
            set: { model?.select(blockID: $0) }
        )
    }

    private func blockLabel(_ block: WorkoutBlock) -> String {
        guard let start = block.startDate else { return "Unscheduled" }
        return start.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Block detail

private struct BlockDetail: View {
    let model: PlannerModel
    let block: WorkoutBlock

    @State private var isPickingDay = false

    var body: some View {
        List {
            headerSection
            daySections
            Section {
                Button("Add Workout Day", systemImage: "calendar.badge.plus") {
                    isPickingDay = true
                }
            }
        }
        .sheet(isPresented: $isPickingDay) {
            DayPickerSheet(block: block) { day in
                model.addPlannedWorkout(on: day)
            }
        }
    }

    private var headerSection: some View {
        Section {
            if let progress = block.progress() {
                LabeledContent("Week") {
                    if let total = progress.totalWeeks {
                        // Reads "week 7 of 6" when a block runs long, rather than
                        // clamping and pretending it's still on schedule.
                        Text("\(progress.weekIndex) of \(total)")
                    } else {
                        Text("\(progress.weekIndex)")
                    }
                }
            }
            if let notes = block.notes, !notes.isEmpty {
                Text(notes).font(.subheadline).foregroundStyle(.secondary)
            }
            if let message = model.loadError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var daySections: some View {
        ForEach(model.programmedDays, id: \.self) { day in
            Section(day.formatted(date: .complete, time: .omitted)) {
                ForEach(model.plannedWorkouts(on: day)) { workout in
                    NavigationLink {
                        PlannedWorkoutEditor(model: model, workoutID: workout.id, day: day)
                    } label: {
                        PlannedWorkoutRow(workout: workout)
                    }
                }
                .onDelete { offsets in
                    let workouts = model.plannedWorkouts(on: day)
                    for index in offsets where index < workouts.count {
                        model.deletePlannedWorkout(id: workouts[index].id)
                    }
                }
            }
        }
    }
}

private struct PlannedWorkoutRow: View {
    let workout: PlannedWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text("\(workout.allSets.count) sets")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        let names = (workout.exercises ?? []).flatMap { $0 }.map(\.exercise.name)
        if names.isEmpty { return "Empty workout" }
        return names.prefix(2).joined(separator: ", ") + (names.count > 2 ? "…" : "")
    }
}

// MARK: - Planned workout editor

private struct PlannedWorkoutEditor: View {
    let model: PlannerModel
    let workoutID: UUID
    let day: Date

    @State private var isPickingExercise = false

    /// Read back through the model rather than held in `@State`, so an edit that
    /// round-trips through the store shows the stored truth instead of a copy
    /// that silently diverges when a write fails.
    private var workout: PlannedWorkout? {
        model.plannedWorkouts(on: day).first { $0.id == workoutID }
    }

    var body: some View {
        Group {
            if let workout {
                List {
                    ForEach(Array((workout.exercises ?? []).enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group) { exercise in
                                PlannedExerciseView(model: model, workout: workout, exercise: exercise)
                            }
                        } header: {
                            if group.count > 1 { Text("Superset") }
                        }
                    }
                    Section {
                        Button("Add Exercise", systemImage: "plus") { isPickingExercise = true }
                    }
                }
            } else {
                ContentUnavailableView("Workout deleted", systemImage: "trash")
            }
        }
        .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
        .sheet(isPresented: $isPickingExercise) {
            PlannerExercisePicker { exercise in
                if let workout { model.addExercise(exercise, to: workout) }
            }
        }
    }
}

private struct PlannedExerciseView: View {
    let model: PlannerModel
    let workout: PlannedWorkout
    let exercise: PlannedExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(exercise.exercise.name).font(.headline)
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive) {
                    model.deleteExercise(id: exercise.id, from: workout)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            ForEach(Array((exercise.sets ?? []).enumerated()), id: \.element.id) { index, set in
                PlannedSetRow(number: index + 1, set: set) { change in
                    model.updateSet(id: set.id, in: workout, change)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        model.deleteSet(id: set.id, in: workout)
                    }
                }
            }

            Button("Add Set", systemImage: "plus.circle") {
                model.addSet(to: exercise.id, in: workout)
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }
}

private struct PlannedSetRow: View {
    let number: Int
    let set: PlannedSet
    let onChange: ((inout PlannedSet) -> Void) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)

            Stepper(
                "\(set.reps ?? 0) reps",
                value: Binding(
                    get: { set.reps ?? 0 },
                    set: { reps in onChange { $0.reps = reps } }
                ),
                in: 1...30
            )
            .font(.subheadline.monospacedDigit())

            Spacer()

            Text(loadSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loadSummary: String {
        switch set.load {
        case .absolute(let weight):
            weight.formatted(.measurement(width: .abbreviated, usage: .personWeight))
        case .percentOf1RM(let percent):
            "\(Int(percent * 100))% 1RM"
        case .rpe(let rpe):
            "RPE \(rpe.formatted())"
        case nil:
            "no load"
        }
    }
}

// MARK: - Sheets

private struct NewBlockSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (Date, Int, String?) -> Void

    @State private var startDate = Date()
    @State private var weeks = 6
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                Stepper("\(weeks) weeks", value: $weeks, in: 1...24)
                TextField("Goal for this block", text: $notes, axis: .vertical)
            }
            .navigationTitle("New Block")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(startDate, weeks, notes.isEmpty ? nil : notes)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct DayPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let block: WorkoutBlock
    let onPick: (Date) -> Void

    @State private var day = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Day", selection: $day, in: range, displayedComponents: .date)
            }
            .navigationTitle("Add Workout Day")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onPick(day)
                        dismiss()
                    }
                }
            }
            .onAppear { day = block.startDate ?? Date() }
        }
    }

    /// Open-ended on the right: a block that runs past its planned end should
    /// still accept new days rather than refusing to schedule them.
    private var range: PartialRangeFrom<Date> {
        (block.startDate ?? .distantPast)...
    }
}

private struct PlannerExercisePicker: View {
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { exercises = (try? environment.exercises.fetchAll()) ?? [] }
        }
    }

    private var filtered: [Exercise] {
        guard !query.isEmpty else { return exercises }
        return exercises.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

#Preview {
    WorkoutPlannerView()
        .environment(AppEnvironment.preview())
}

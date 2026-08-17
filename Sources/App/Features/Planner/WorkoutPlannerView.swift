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
        guard let user = environment.currentUser else { return }
        guard model == nil else {
            // Maxes can change between visits (a set logged in the tracker
            // records a new achieved max), and every %-of-max weight on this
            // screen resolves against them.
            model?.user = user
            model?.load()
            return
        }
        let model = PlannerModel(plans: environment.plans, userID: user.id, user: user)
        model.load()
        self.model = model
    }

    @ViewBuilder
    private func content(_ model: PlannerModel) -> some View {
        if model.selectedBlock != nil {
            BlockOverview(model: model)
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

// MARK: - Block overview

/// The block at a glance: weeks, days, and every day's actual prescription.
///
/// The spreadsheet this replaces shows the whole week's programming without a
/// click, and `Workout Planner.md` asks for "a compact view of the information
/// taking full advantage of screen real estate". So the weight, reps, and
/// effort are on this screen — tapping a day is for *editing* it, not for
/// finding out what's in it.
///
/// Weeks collapse because a 12-week block is ~70 programmed days; the current
/// one is open by default, which is the doc's "default focus is on the current
/// area of the lift".
private struct BlockOverview: View {
    let model: PlannerModel

    @State private var isPickingDay = false
    @State private var editing: PlannedWorkout?
    @State private var collapsedWeeks: Set<Int> = []
    @State private var didSetInitialFocus = false

    var body: some View {
        List {
            headerSection
            weekSections
            addDayButton
        }
        .listStyle(.plain)
        .screenGround()
        .sheet(isPresented: $isPickingDay) {
            if let block = model.selectedBlock {
                DayPickerSheet(block: block) { day in
                    model.addPlannedWorkout(on: day)
                }
            }
        }
        .navigationDestination(item: $editing) { workout in
            PlannedWorkoutEditor(model: model, workout: workout)
        }
        .onAppear {
            focusCurrentWeek()
            openLaunchArgumentDay()
        }
    }

    /// `-openPlanDay N` — the only way to see the day editor from the command
    /// line, since simctl can't tap. Inert without the argument.
    private func openLaunchArgumentDay() {
        guard editing == nil, let index = LaunchArguments.planDayIndex else { return }
        let days = model.programmedWeeks.flatMap(\.days)
        guard days.indices.contains(index) else { return }
        editing = model.plannedWorkouts(on: days[index]).first
    }

    /// Opens the week the lifter is actually in and collapses the rest. Only
    /// once per appearance of the screen — re-running it would fight the
    /// lifter every time they expanded a different week.
    private func focusCurrentWeek() {
        guard !didSetInitialFocus else { return }
        didSetInitialFocus = true
        guard let current = model.currentWeekIndex() else { return }
        collapsedWeeks = Set(model.programmedWeeks.map(\.index)).subtracting([current])
    }

    // MARK: Sections

    @ViewBuilder
    private var headerSection: some View {
        if let block = model.selectedBlock {
            Panel {
                VStack(alignment: .leading, spacing: 9) {
                    if let progress = block.progress(asOf: Date(), calendar: model.calendar) {
                        // Reads "7 / 6" when a block runs long, rather than clamping
                        // and pretending it's still on schedule.
                        Readout(
                            label: "week",
                            value: progress.totalWeeks.map { "\(progress.weekIndex) / \($0)" }
                                ?? "\(progress.weekIndex)",
                            accent: Theme.signal,
                            size: 17
                        )
                    }
                    if let notes = block.notes, !notes.isEmpty {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Text(notes)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
            }
            .panelRow()
        }

        if let message = model.loadError {
            Panel(accent: Theme.alert.opacity(0.5)) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.alert)
            }
            .panelRow()
        }
    }

    @ViewBuilder
    private var weekSections: some View {
        let current = model.currentWeekIndex()
        ForEach(model.programmedWeeks) { week in
            WeekHeaderRow(
                week: week,
                isCurrent: week.index == current,
                isCollapsed: collapsedWeeks.contains(week.index),
                setCount: setCount(in: week),
                onToggle: { toggle(week.index) }
            )
            .panelRow()

            if !collapsedWeeks.contains(week.index) {
                ForEach(week.days, id: \.self) { day in
                    daySection(day)
                }
            }
        }
    }

    @ViewBuilder
    private func daySection(_ day: Date) -> some View {
        let workouts = model.plannedWorkouts(on: day)
        let isToday = model.calendar.isDateInToday(day)

        ForEach(workouts) { workout in
            Button {
                editing = workout
            } label: {
                PlannedDayPanel(
                    workout: workout,
                    day: day,
                    isToday: isToday,
                    resolve: { model.resolvedWeight(for: $0, exercise: $1) }
                )
            }
            .buttonStyle(.plain)
            .panelRow()
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.deletePlannedWorkout(id: workout.id)
                }
            }
        }
    }

    private var addDayButton: some View {
        Button { isPickingDay = true } label: {
            Label("Add Workout Day", systemImage: "calendar.badge.plus")
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

    private func toggle(_ index: Int) {
        if collapsedWeeks.contains(index) {
            collapsedWeeks.remove(index)
        } else {
            collapsedWeeks.insert(index)
        }
    }

    private func setCount(in week: WorkoutBlock.ProgrammedWeek) -> Int {
        week.days.reduce(0) { total, day in
            total + model.plannedWorkouts(on: day).reduce(0) { $0 + $1.allSets.count }
        }
    }
}

private struct WeekHeaderRow: View {
    let week: WorkoutBlock.ProgrammedWeek
    let isCurrent: Bool
    let isCollapsed: Bool
    let setCount: Int
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkFaint)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text("WEEK \(week.index)")
                    .font(Theme.label)
                    .tracking(1.6)
                    .foregroundStyle(isCurrent ? Theme.live : Theme.inkFaint)
                    .fixedSize()
                if isCurrent {
                    Chip(text: "now", color: Theme.live)
                }
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                Text("\(week.days.count)d · \(setCount) sets")
                    .font(Theme.data(10))
                    .foregroundStyle(Theme.inkFaint)
                    .fixedSize()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}

// MARK: - Day panel

/// A programmed day with its full prescription visible — the density the
/// spreadsheet had.
private struct PlannedDayPanel: View {
    let workout: PlannedWorkout
    let day: Date
    let isToday: Bool
    let resolve: (LoadPrescription, Exercise) -> Measurement<UnitMass>?

    var body: some View {
        Panel(accent: accent) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if exercises.isEmpty {
                    Text("Nothing programmed.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkFaint)
                } else {
                    ForEach(exercises) { exercise in
                        PlannedExerciseLine(exercise: exercise, resolve: resolve)
                    }
                }
            }
        }
        // Skipped stays visible, per Core Tenets §10 — dimmed, not hidden.
        .opacity(workout.skippedAt != nil ? 0.55 : 1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())
                .font(Theme.label)
                .tracking(1.4)
                .foregroundStyle(isToday ? Theme.live : Theme.inkFaint)
                .fixedSize()
            if let label = workout.notes, !label.isEmpty {
                Text(label)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if workout.skippedAt != nil {
                Chip(text: "skipped", color: Theme.inkFaint)
            }
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12))
                .foregroundStyle(Theme.signal)
                .fixedSize()
        }
    }

    private var accent: Color {
        if workout.skippedAt != nil { return Theme.hairline }
        return isToday ? Theme.live.opacity(0.5) : Theme.signal.opacity(0.4)
    }

    private var exercises: [PlannedExercise] {
        (workout.exercises ?? []).flatMap { $0 }
    }
}

/// One exercise's prescription, on one line where it fits.
///
/// Width-agnostic: the name is the only flexible element and the only thing
/// allowed to truncate — it's the most redundant part of the line (you can tell
/// "Barbell Bench Press - Medi…" from "Barbell Squat"), while a truncated
/// weight or rep count would read as corrupted data.
private struct PlannedExerciseLine: View {
    let exercise: PlannedExercise
    let resolve: (LoadPrescription, Exercise) -> Measurement<UnitMass>?

    var body: some View {
        let groups = exercise.setGroups

        VStack(alignment: .leading, spacing: 3) {
            if groups.count == 1 {
                // The common case — one uniform prescription fits beside the
                // name.
                HStack(spacing: 8) {
                    name
                    Spacer(minLength: 6)
                    PrescriptionText(group: groups[0], exercise: exercise.exercise, resolve: resolve)
                }
            } else {
                name
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    HStack {
                        PrescriptionText(group: group, exercise: exercise.exercise, resolve: resolve)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 12)
                }
            }
        }
    }

    private var name: some View {
        HStack(spacing: 5) {
            Text(exercise.displayName)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if exercise.exercise.isOpenChoice {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkFaint)
                    .fixedSize()
            }
        }
    }
}

/// "5×2 · 405 lb · @7" — the prescription for one run of identical sets.
private struct PrescriptionText: View {
    let group: PlannedExercise.SetGroup
    let exercise: Exercise
    let resolve: (LoadPrescription, Exercise) -> Measurement<UnitMass>?

    var body: some View {
        HStack(spacing: 8) {
            Text(countText)
                .font(Theme.data(12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize()
            if let loadText {
                Text(loadText)
                    .font(Theme.data(12))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize()
            }
            if let effort = group.effort {
                Text("@\(effort.rpe.rpeDescription)")
                    .font(Theme.data(12))
                    .foregroundStyle(Theme.signal)
                    .fixedSize()
            }
        }
    }

    private var countText: String {
        guard let reps = group.reps else { return "\(group.count)×" }
        return "\(group.count)×\(reps)"
    }

    /// The resolved weight where the referenced max exists, otherwise the
    /// prescription exactly as written — "72% goal" beats showing nothing when
    /// no goal max is on record (Core Tenets §10).
    private var loadText: String? {
        guard let load = group.load else { return nil }
        if let weight = resolve(load, exercise) {
            return weight.liftedDescription
        }
        return load.prescriptionDescription
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

#Preview {
    WorkoutPlannerView()
        .environment(AppEnvironment.preview())
}

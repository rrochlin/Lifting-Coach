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
    @State private var editMode: EditMode = .inactive
    /// The current calendar week's plan — a lifter should be able to see (and
    /// start, or skip) more than just today.
    @State private var weekPlan: [PlannedWorkout] = []

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
        .environment(\.editMode, $editMode)
        .task {
            if model == nil, let userID = environment.currentUser?.id {
                let model = TrackerModel(
                    workouts: environment.workouts,
                    users: environment.users,
                    exercises: environment.exercises,
                    userID: userID,
                    onAchievedMaxRecorded: { environment.reloadUser() }
                )
                model.resumeIfNeeded()
                self.model = model
            }
            loadWeek()
        }
        .sheet(isPresented: $isPickingExercise) {
            ExercisePicker { exercise in
                model?.addExercise(exercise, sets: 1)
            }
        }
    }

    // MARK: Idle — week view

    @ViewBuilder
    private var idle: some View {
        List {
            if weekPlan.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NO SESSION")
                            .font(Theme.label)
                            .tracking(1.6)
                            .foregroundStyle(Theme.inkFaint)
                        Text("Nothing programmed this week.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.ink)
                    }
                }
                .panelRow()
            } else {
                ForEach(weekDays, id: \.self) { day in
                    daySection(day)
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
        .refreshable { loadWeek() }
    }

    @ViewBuilder
    private func daySection(_ day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)

        HStack(spacing: 8) {
            SectionLabel(
                text: day.formatted(.dateTime.weekday(.wide).month().day()),
                accent: isToday ? Theme.live : Theme.inkFaint
            )
            if isToday {
                Chip(text: "today", color: Theme.live)
            }
        }
        .panelRow()

        ForEach(workouts(on: day)) { workout in
            Button {
                if workout.skippedAt == nil { start(workout) }
            } label: {
                PlannedSummaryRow(workout: workout, isToday: isToday)
            }
            .buttonStyle(.plain)
            .panelRow()
            .swipeActions(edge: .trailing) {
                if workout.skippedAt == nil {
                    Button("Skip", systemImage: "arrow.uturn.forward") { skip(workout) }
                        .tint(Theme.inkFaint)
                } else {
                    Button("Unskip", systemImage: "arrow.uturn.backward") { unskip(workout) }
                        .tint(Theme.signal)
                }
            }
        }
    }

    /// Distinct programmed days within the loaded week, in order.
    private var weekDays: [Date] {
        let calendar = Calendar.current
        let days = Set(weekPlan.compactMap { $0.date.map { calendar.startOfDay(for: $0) } })
        return days.sorted()
    }

    private func workouts(on day: Date) -> [PlannedWorkout] {
        let calendar = Calendar.current
        return weekPlan.filter { $0.date.map { calendar.isDate($0, inSameDayAs: day) } == true }
    }

    /// Monday–Sunday containing today — chosen over an arbitrary ±N-day window
    /// because the program itself is organized into weekly grids
    /// (`WorkoutBlock.program`), so a week-aligned window always shows a
    /// complete week, catch-up days behind and preview days ahead, without
    /// straddling two program weeks.
    private func loadWeek() {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        guard let week = calendar.dateInterval(of: .weekOfYear, for: Date()) else { return }
        // dateInterval's end is the start of the *following* week (exclusive),
        // so step back a day to land on this week's actual last day.
        let lastDay = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.end
        weekPlan = (try? environment.plans.fetchPlanned(from: week.start, to: lastDay)) ?? []
    }

    private func skip(_ workout: PlannedWorkout) {
        try? environment.plans.markSkipped(workoutID: workout.id)
        loadWeek()
    }

    private func unskip(_ workout: PlannedWorkout) {
        try? environment.plans.unmarkSkipped(workoutID: workout.id)
        loadWeek()
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

    // MARK: Active workout

    private func activeWorkout(_ model: TrackerModel) -> some View {
        ActiveWorkoutList(
            model: model,
            onAddExercise: { isPickingExercise = true },
            onRequestFinish: { isConfirmingFinish = true }
        )
        .themedConfirm(
            isPresented: $isConfirmingFinish,
            title: "Finish this workout?",
            message: finishWarning(for: model),
            confirmLabel: "Finish",
            cancelLabel: "Keep Going",
            onConfirm: { model.finish() }
        )
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
                // Drives drag-to-reorder for both exercise groups and sets —
                // SwiftUI wires EditButton to the shared \.editMode binding
                // automatically, and suppresses .swipeActions while active so
                // reorder and delete never contend for the same gesture.
                EditButton()
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

    /// Per-exercise expand override. Absent means "default to expanded only if
    /// this is the active exercise" — a manual tap can push either direction.
    @State private var expandedOverrides: [UUID: Bool] = [:]
    @State private var noteEditorTarget: NoteEditorTarget?
    /// The exercise whose slot is being filled — an open-choice slot being
    /// resolved, or any exercise being swapped mid-workout.
    @State private var choosingFor: ChoosingTarget?

    var body: some View {
        List {
            statusSection
            groupSections
            actionSection
        }
        .listStyle(.plain)
        .screenGround()
        .sheet(item: $noteEditorTarget) { target in
            NoteEditorSheet(
                programmedNote: programmedNote(for: target),
                usernote: usernoteBinding(for: target)
            )
        }
        .sheet(item: $choosingFor) { target in
            ExercisePicker(initialMuscleFilter: target.muscleGroup) { picked in
                // Recording what actually filled the slot: the logged exercise
                // becomes the real movement, so history and achieved-max
                // tracking reference something specific rather than a goal.
                model.updateExercise(id: target.id) { $0.exercise = picked }
            }
        }
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
        if let record = model.newAchievedMax {
            AchievedMaxBanner(exercise: record.exercise, max: record.max) {
                model.dismissAchievedMaxBanner()
            }
            .panelRow()
        }
    }

    @ViewBuilder
    private var groupSections: some View {
        let groups = model.session?.exerciseGroups ?? []
        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
            if group.count > 1 {
                SectionLabel(text: "superset", accent: Theme.signal)
                    .panelRow()
                    .padding(.top, groupIndex == 0 ? 0 : 8)
            }
            ForEach(group) { exercise in
                exerciseRows(exercise: exercise, groupIndex: groupIndex)
            }
        }
        // Reorders whole exercise groups (supersets move together). Known
        // limit: this doesn't reorder the two exercises *within* one superset
        // pair, matching moveGroup's existing group-level granularity.
        .onMove { offsets, destination in
            guard let source = offsets.first else { return }
            model.moveGroup(from: source, to: destination)
        }
    }

    @ViewBuilder
    private func exerciseRows(exercise: WorkoutExercise, groupIndex: Int) -> some View {
        let isActiveGroup = model.session?.activeExercise?.group == groupIndex
        // Defaults to expanded only for the exercise currently being worked;
        // a tap can override in either direction without losing the default
        // once the workout moves on to the next lift.
        let expanded = expandedOverrides[exercise.id] ?? isActiveGroup
        let sets = exercise.sets ?? []
        let isRestingHere = model.restingExerciseID == exercise.id && model.restEndsAt != nil
        let accent = isActiveGroup ? Theme.live.opacity(0.55) : Theme.hairline

        ExerciseHeaderRow(
            exercise: exercise,
            isActive: isActiveGroup,
            isExpanded: expanded,
            onToggleExpanded: { expandedOverrides[exercise.id] = !expanded },
            onDelete: { model.deleteExercise(id: exercise.id) },
            onEditNote: { noteEditorTarget = .exercise(exercise.id) },
            onChooseExercise: {
                choosingFor = ChoosingTarget(
                    id: exercise.id,
                    muscleGroup: exercise.exercise.isOpenChoice ? exercise.exercise.muscleGroup : nil
                )
            }
        )
        .panelGroupRow(expanded ? .top : .single, accent: accent)

        if expanded {
            ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                SetRow(
                    number: index + 1,
                    set: set,
                    isNextUp: model.session?.nextSet?.id == set.id,
                    restTarget: model.session?.restTarget(afterSetWith: set.id) ?? 120,
                    onToggle: { toggle(set) },
                    onRepsChange: { reps in model.updateSet(id: set.id) { $0.reps = reps } },
                    onWeightChange: { weight in model.updateSet(id: set.id) { $0.weight = weight } },
                    onRPEChange: { rpe in model.updateSet(id: set.id) { $0.rpe = rpe } },
                    onEditNote: { noteEditorTarget = .set(set.id) }
                )
                .panelGroupRow(.middle, accent: accent)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        model.deleteSet(id: set.id)
                    }
                }
            }
            .onMove { offsets, destination in
                guard let source = offsets.first else { return }
                model.moveSet(from: source, to: destination, within: exercise.id)
            }

            if isRestingHere, let endsAt = model.restEndsAt {
                RestTimerRow(endsAt: endsAt) { model.dismissRest() }
                    .panelGroupRow(.middle, accent: Theme.live)
            }

            Button { model.addSet(toExerciseWith: exercise.id) } label: {
                Label("Add Set", systemImage: "plus")
                    .font(Theme.data(11, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(.plain)
            .panelGroupRow(.bottom, accent: accent)
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

    // MARK: Notes

    private func programmedNote(for target: NoteEditorTarget) -> String? {
        guard let groups = model.session?.exerciseGroups else { return nil }
        switch target {
        case .exercise(let id):
            return groups.flatMap { $0 }.first { $0.id == id }?.notes
        case .set(let id):
            return groups.flatMap { $0 }
                .flatMap { $0.sets ?? [] }
                .first { $0.id == id }?
                .plannedFrom?.notes
        }
    }

    private func usernoteBinding(for target: NoteEditorTarget) -> Binding<String> {
        Binding(
            get: {
                guard let groups = model.session?.exerciseGroups else { return "" }
                switch target {
                case .exercise(let id):
                    return groups.flatMap { $0 }.first { $0.id == id }?.usernotes ?? ""
                case .set(let id):
                    return groups.flatMap { $0 }
                        .flatMap { $0.sets ?? [] }
                        .first { $0.id == id }?
                        .usernotes ?? ""
                }
            },
            set: { newValue in
                let note = newValue.isEmpty ? nil : newValue
                switch target {
                case .exercise(let id):
                    model.updateExercise(id: id) { $0.usernotes = note }
                case .set(let id):
                    model.updateSet(id: id) { $0.usernotes = note }
                }
            }
        )
    }
}

/// Which exercise slot the picker is filling, and what to pre-filter it by.
private struct ChoosingTarget: Identifiable {
    let id: UUID
    /// Non-nil for an open-choice slot — the muscle group the coach specified,
    /// used to pre-filter the picker to plausible choices.
    let muscleGroup: String?
}

/// Identifies which planned-vs-logged item the note editor sheet is open on.
private enum NoteEditorTarget: Identifiable {
    case exercise(UUID)
    case set(UUID)

    var id: UUID {
        switch self {
        case .exercise(let id), .set(let id): id
        }
    }
}

// MARK: - Planned summary

private struct PlannedSummaryRow: View {
    let workout: PlannedWorkout
    let isToday: Bool

    var body: some View {
        Panel(accent: accent) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    // The plan's own day label ("Week 1 Mon - Bench+Squat") is
                    // the title; the exercise list is a subtitle, truncated —
                    // spelling out all 5-6 names wraps to four lines and buries
                    // everything below it.
                    Text(title)
                        .font(Theme.heading)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if workout.skippedAt != nil {
                        Chip(text: "skipped", color: Theme.inkFaint)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.signal)
                    }
                }
                if !names.isEmpty {
                    Text(names.joined(separator: " · "))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(2)
                }
                Text("\(workout.allSets.count) SETS")
                    .font(Theme.label)
                    .tracking(1.4)
                    .foregroundStyle(workout.skippedAt != nil ? Theme.inkFaint : Theme.signal)
            }
        }
        // Skipped stays visible, per Core Tenets §10 — dimmed, not hidden.
        .opacity(workout.skippedAt != nil ? 0.55 : 1)
    }

    private var accent: Color {
        if workout.skippedAt != nil { return Theme.hairline }
        return isToday ? Theme.live.opacity(0.5) : Theme.signal.opacity(0.45)
    }

    /// The plan's day label, falling back to the exercise list for an ad-hoc
    /// or unlabeled day.
    private var title: String {
        if let notes = workout.notes, !notes.isEmpty { return notes }
        return names.isEmpty ? "Empty workout" : names.joined(separator: " / ")
    }

    private var names: [String] {
        (workout.exercises ?? []).flatMap { $0 }.map(\.exercise.name)
    }
}

// MARK: - Exercise header

private struct ExerciseHeaderRow: View {
    let exercise: WorkoutExercise
    let isActive: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onDelete: () -> Void
    let onEditNote: () -> Void
    let onChooseExercise: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpanded) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(exercise.exercise.name)
                        .font(Theme.heading)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if isActive {
                        Chip(text: "active", color: Theme.live)
                    }
                    // The coach specified a goal, not a movement — a reminder
                    // to pick your own implementation, and a signal that this
                    // exercise doesn't track an achieved max.
                    if exercise.exercise.isOpenChoice {
                        Chip(text: "your choice", color: Theme.inkMuted)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            if !isExpanded {
                Text(collapsedProgress)
                    .font(Theme.data(12))
                    .foregroundStyle(Theme.inkMuted)
            }

            if let notes = exercise.usernotes, !notes.isEmpty {
                Image(systemName: "note.text")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.signal)
            }

            Menu {
                // An open-choice slot names a goal, not a movement — recording
                // which exercise actually filled it is the whole point, so it
                // leads the menu while unresolved.
                Button(
                    exercise.exercise.isOpenChoice ? "Choose Exercise" : "Swap Exercise",
                    systemImage: "arrow.triangle.2.circlepath",
                    action: onChooseExercise
                )
                Button("Edit Note", systemImage: "note.text", action: onEditNote)
                Button("Delete Exercise", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private var collapsedProgress: String {
        let sets = exercise.sets ?? []
        guard !sets.isEmpty else { return "0 SETS" }
        let done = sets.filter { $0.complete == true }.count
        return "\(done)/\(sets.count)"
    }
}

// MARK: - Set row

private struct SetRow: View {
    let number: Int
    let set: WorkoutSet
    let isNextUp: Bool
    /// Seconds of rest this set is prescribed — shown before it's performed so
    /// the lifter knows what they're resting for, not just that a clock is
    /// running.
    let restTarget: Int
    let onToggle: () -> Void
    let onRepsChange: (Int?) -> Void
    let onWeightChange: (Measurement<UnitMass>?) -> Void
    let onRPEChange: (Float?) -> Void
    let onEditNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            quantities
            annotations
        }
        .padding(.vertical, 2)
    }

    /// Every quantity is visible and directly tappable — no expand step. Reps
    /// and weight are inline text fields; RPE is a menu constrained to the
    /// app's 1–10 by 0.5 scale (Core Tenets §3), so an out-of-range or
    /// RIR-scaled value can't be entered.
    private var quantities: some View {
        HStack(spacing: 8) {
            checkboxButton

            Text(String(format: "%02d", number))
                .font(Theme.data(11))
                .foregroundStyle(Theme.inkFaint)

            numberField(value: repsBinding, width: 34, format: .number)
            Text("×")
                .font(Theme.data(12))
                .foregroundStyle(Theme.inkFaint)
            numberField(
                value: weightBinding,
                width: 62,
                format: .number.precision(.fractionLength(0...2))
            )
            Text(weightUnit.symbol)
                .font(Theme.data(11))
                .foregroundStyle(Theme.inkFaint)

            Spacer(minLength: 4)

            Picker("", selection: rpeBinding) {
                Text("RPE —").tag(Float?.none)
                ForEach(rpeOptions, id: \.self) { value in
                    Text("RPE \(value.rpeDescription)").tag(Float?.some(value))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(Theme.data(12))
            .tint(self.set.rpe == nil ? Theme.inkFaint : Theme.ink)

            Button(action: onEditNote) {
                Image(systemName: hasNote ? "note.text" : "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(hasNote ? Theme.signal : Theme.inkFaint)
            }
            .buttonStyle(.plain)
        }
    }

    /// The quiet second line: what was prescribed, and the rest — planned
    /// before the set is done, actually taken after.
    private var annotations: some View {
        HStack(spacing: 10) {
            Text(restLabel)
                .font(Theme.data(10))
                .foregroundStyle(done ? Theme.inkMuted : Theme.inkFaint)

            if let prescription {
                Text(prescription)
                    .font(Theme.data(10))
                    .foregroundStyle(setTypeAccent)
            }

            Spacer(minLength: 0)

            if let type = self.set.type, type != .working {
                Text(type.rawValue.uppercased())
                    .font(Theme.label)
                    .tracking(1.1)
                    .foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.leading, 40)
    }

    private func numberField<F: ParseableFormatStyle>(
        value: Binding<F.FormatInput>,
        width: CGFloat,
        format: F
    ) -> some View where F.FormatOutput == String {
        TextField("", value: value, format: format)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .font(Theme.data(15, weight: done ? .regular : .medium))
            .foregroundStyle(done ? Theme.inkMuted : Theme.ink)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .padding(.vertical, 3)
            .background(Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Before the set is logged this is the target ("rest 2:00"); after, it's
    /// what was actually taken ("rested 3:05"), which `completeSet` measures
    /// from the previous completed set.
    private var restLabel: String {
        if done, let actual = self.set.restTime {
            return "rested \(formatted(actual))"
        }
        return "rest \(formatted(restTarget))"
    }

    private func formatted(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var checkboxButton: some View {
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
    }

    // `self.` throughout: a bare `set` opening a computed property's body
    // parses as the start of a setter declaration.
    private var done: Bool { self.set.complete == true }
    private var hasNote: Bool { !(self.set.usernotes ?? "").isEmpty }

    private var repsBinding: Binding<Int> {
        Binding(get: { self.set.reps ?? 0 }, set: { onRepsChange($0) })
    }

    private var weightBinding: Binding<Double> {
        Binding(
            get: { self.set.weight?.value ?? 0 },
            set: { onWeightChange(Measurement(value: $0, unit: weightUnit)) }
        )
    }

    private var rpeBinding: Binding<Float?> {
        Binding(get: { self.set.rpe }, set: { onRPEChange($0) })
    }

    private var rpeOptions: [Float] {
        stride(from: Float(1), through: Float(10), by: 0.5).map { $0 }
    }

    /// Where to resolve the weight field's unit from when the set doesn't
    /// have one yet: its own weight, then the prescribed absolute load, then a
    /// plain default. No app-wide unit preference exists to consult here.
    private var weightUnit: UnitMass {
        if let unit = self.set.weight?.unit { return unit }
        if case .absolute(let weight) = self.set.plannedFrom?.load { return weight.unit }
        return .pounds
    }

    /// Warmups read quieter than working sets — the HUD annotation layer
    /// carries set type without spending a column on it.
    private var setTypeAccent: Color {
        // `self.` is required: a bare `set` starting the body of a computed
        // property parses as the start of a setter declaration.
        self.set.type == .warmup ? Theme.inkFaint : Theme.inkMuted
    }

    /// What was *prescribed* — the logged values now have their own always-
    /// visible controls, so this line carries only the target being chased:
    /// the effort target, and the load as written when it differs from the
    /// resolved weight (Core Tenets §10 — "80% goal" beats showing nothing).
    private var prescription: String? {
        var parts: [String] = []

        // The effort target rides in the snapshot, materialized from the
        // exercise at workout start.
        if let target = self.set.plannedFrom?.effort?.rpe {
            parts.append("target RPE \(target.rpeDescription)")
        }
        if case .percentOf = self.set.plannedFrom?.load,
           let load = self.set.plannedFrom?.load {
            parts.append(load.prescriptionDescription)
        }
        if let plannedReps = self.set.plannedFrom?.reps,
           let actual = self.set.reps,
           plannedReps != actual {
            parts.append("planned \(plannedReps)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Note editor

private struct NoteEditorSheet: View {
    let programmedNote: String?
    @Binding var usernote: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let programmedNote, !programmedNote.isEmpty {
                    SectionLabel(text: "programmed", accent: Theme.inkFaint)
                    Text(programmedNote)
                        .font(Theme.body)
                        .foregroundStyle(Theme.inkMuted)
                }

                SectionLabel(text: "your note", accent: Theme.signal)
                TextEditor(text: $usernote)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Spacer()
            }
            .padding(16)
            .background(Theme.void)
            .navigationTitle("Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Achieved max banner

private struct AchievedMaxBanner: View {
    let exercise: Exercise
    let max: AchievedMax
    let onDismiss: () -> Void

    var body: some View {
        Panel(accent: Theme.live) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.live)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEW MAX")
                        .font(Theme.label)
                        .tracking(1.6)
                        .foregroundStyle(Theme.live)
                    Text("\(exercise.name.uppercased()) — \(max.weight.liftedDescription)")
                        .font(Theme.data(15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                Spacer()
                Button("OK", action: onDismiss)
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.inkMuted)
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Rest timer

private struct RestTimerRow: View {
    let endsAt: Date
    let onDismiss: () -> Void

    var body: some View {
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

// MARK: - Exercise picker

private struct ExercisePicker: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Pre-selects a muscle filter — set when filling an open-choice slot the
    /// coach targeted at a specific muscle group.
    var initialMuscleFilter: String?
    let onPick: (Exercise) -> Void

    @State private var exercises: [Exercise] = []
    @State private var query = ""
    @State private var muscleFilter: String?
    @State private var equipmentFilter: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                List(filtered) { exercise in
                    Button {
                        onPick(exercise)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                            HStack(spacing: 4) {
                                Text(exercise.muscleGroup)
                                if let equipment = exercise.equipment {
                                    Text("· \(equipment.capitalized)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query)
            .navigationTitle(initialMuscleFilter == nil ? "Add Exercise" : "Choose Exercise")
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
                if muscleFilter == nil { muscleFilter = initialMuscleFilter }
            }
        }
    }

    /// Muscle and equipment chips. Lift-family grouping (Larsen/Spoto/close-grip
    /// as bench variations) isn't here yet — that needs a real notion of family
    /// on the catalog, not a name-substring guess.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(muscleOptions, id: \.self) { muscle in
                    filterChip(muscle, isOn: muscleFilter == muscle) {
                        muscleFilter = muscleFilter == muscle ? nil : muscle
                    }
                }
                Divider().frame(height: 18)
                ForEach(equipmentOptions, id: \.self) { equipment in
                    filterChip(equipment.capitalized, isOn: equipmentFilter == equipment) {
                        equipmentFilter = equipmentFilter == equipment ? nil : equipment
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.data(11))
                .foregroundStyle(isOn ? Theme.void : Theme.inkMuted)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(isOn ? Theme.signal : Theme.panelRaised)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var muscleOptions: [String] {
        Array(Set(exercises.map(\.muscleGroup))).sorted()
    }

    private var equipmentOptions: [String] {
        Array(Set(exercises.compactMap(\.equipment))).sorted()
    }

    private var filtered: [Exercise] {
        exercises.filter { exercise in
            if let muscleFilter, exercise.muscleGroup != muscleFilter { return false }
            if let equipmentFilter, exercise.equipment != equipmentFilter { return false }
            if !query.isEmpty, !exercise.name.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }
}

#Preview {
    WorkoutTrackerView()
        .environment(AppEnvironment.preview())
}

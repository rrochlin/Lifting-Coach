import SwiftUI
import LiftingCoachModel

/// One logged workout — read, and corrected.
///
/// History had no way in at all before this screen existed: rows showed a date
/// and a name list and did nothing when tapped, which was survivable with three
/// workouts on the device and useless with five years of them.
///
/// Editing is the second half, and it is deliberately the **planner's** shape
/// rather than the tracker's. The tracker saves after every mutation because a
/// session the OS kills mid-workout has to be recoverable; there is nothing to
/// recover here, and a half-typed weight shouldn't overwrite a set logged in
/// March on its way to being finished. So the screen has two modes: it reads by
/// default, and edits into a `LoggedWorkoutDraft` that lands on an explicit
/// SAVE, with a confirmation on the way out.
///
/// What editing deliberately doesn't reach: `source` and each set's
/// `plannedFrom` snapshot, both of which are facts about where a row came from
/// rather than what was lifted (see `LoggedWorkoutDraft`). And **achieved maxes
/// are not replayed** — correcting a 500 lb squat down to 405 leaves the max
/// event that was recorded at the time. `achievedMax` is append-only event
/// history by design (Core Tenets §6), so rebuilding it from the log is a
/// separate decision, written down in `notes/Feedback.md` rather than made
/// quietly here. `exerciseStats` *is* rebuilt on save, because that table is
/// derived and rebuilding is its only write path.
struct WorkoutDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let workoutID: UUID
    /// Told when this workout has been rewritten or removed, so the list that
    /// pushed this screen can stop showing a row that no longer matches the log.
    var onChange: (() -> Void)?

    @State private var draft: LoggedWorkoutDraft?
    @State private var isEditing = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingDelete = false
    @State private var noteTarget: NoteTarget?

    var body: some View {
        List {
            if let loadError {
                errorPanel(loadError)
            } else if draft != nil {
                if let saveError { errorPanel(saveError) }
                problemsPanel
                summarySection
                exerciseSections
                if isEditing { deleteWorkoutButton }
            }
        }
        .listStyle(.plain)
        .screenGround()
        .navigationTitle(titleText)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Only while dirty: with nothing to lose, the system's back gesture and
        // button should behave exactly as they do everywhere else.
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar { toolbar }
        .sheet(item: $noteTarget) { target in
            NoteSheet(
                title: noteTitle(for: target),
                context: prescribedNote(for: target).map { ("prescribed", $0) },
                note: noteBinding(for: target)
            )
        }
        .themedConfirm(
            isPresented: $isConfirmingDiscard,
            title: "Discard changes?",
            message: "This workout's edits haven't been saved.",
            confirmLabel: "Discard",
            cancelLabel: "Keep Editing",
            onConfirm: {
                draft?.revert()
                isEditing = false
            }
        )
        .themedConfirm(
            isPresented: $isConfirmingDelete,
            title: "Delete this workout?",
            message: deleteMessage,
            confirmLabel: "Delete",
            cancelLabel: "Keep",
            onConfirm: deleteWorkout
        )
        .task { load() }
    }

    // MARK: - Header

    @ViewBuilder
    private func errorPanel(_ message: String) -> some View {
        Panel(accent: Theme.alert.opacity(0.5)) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.caption)
                .foregroundStyle(Theme.alert)
        }
        .panelRow()
    }

    /// Why the save button is off. Said out loud rather than left as a greyed
    /// button with no explanation — the app reports a contradiction instead of
    /// resolving it on the lifter's behalf (Core Tenets §1).
    @ViewBuilder
    private var problemsPanel: some View {
        if let problems = draft?.problems, !problems.isEmpty {
            Panel(accent: Theme.alert.opacity(0.5)) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.self) { problem in
                        Text(problem.message)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.alert)
                    }
                }
            }
            .panelRow()
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let workout = draft?.workout {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    if isEditing {
                        editableSummary(workout)
                    } else {
                        readOnlySummary(workout)
                    }
                }
            }
            .panelRow()
        }
    }

    @ViewBuilder
    private func readOnlySummary(_ workout: Workout) -> some View {
        if let notes = workout.notes, !notes.isEmpty {
            Text(notes)
                .font(Theme.heading)
                .foregroundStyle(Theme.ink)
        }
        Readout(label: "date", value: dateText(workout))
        if let durationText = durationText(workout) {
            Readout(label: "duration", value: durationText)
        }
        Readout(label: "sets", value: "\(workout.allSets.filter { $0.complete == true }.count)")
        if let source = workout.source {
            Readout(label: "source", value: source, accent: Theme.inkFaint)
        }
        if let usernotes = workout.usernotes, !usernotes.isEmpty {
            Text(usernotes)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkMuted)
        }
    }

    /// Title and both ends of the session.
    ///
    /// The two times are separate fields with no coupling: moving the start
    /// deliberately doesn't drag the end along behind it. An inverted range is
    /// reported by `problems` and blocks the save instead.
    @ViewBuilder
    private func editableSummary(_ workout: Workout) -> some View {
        SectionLabel(text: "title")
        TextField(
            "e.g. Legs",
            text: Binding(
                get: { draft?.workout.notes ?? "" },
                set: { draft?.setTitle($0) }
            )
        )
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .textFieldStyle(.plain)
        // Outlined like every other editable value in the app. A text field
        // drawn as plain text reads as a label, which is the complaint that
        // produced `editableField` in the first place.
        .editableField()

        SectionLabel(text: "started")
        DatePicker(
            "Started",
            selection: Binding(
                get: { draft?.workout.startTime ?? Date() },
                set: { draft?.setStartTime($0) }
            ),
            displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .tint(Theme.signal)

        SectionLabel(text: "ended")
        HStack {
            if workout.endTime != nil {
                DatePicker(
                    "Ended",
                    selection: Binding(
                        get: { draft?.workout.endTime ?? Date() },
                        set: { draft?.setEndTime($0) }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(Theme.signal)
            } else {
                Button("SET END TIME") {
                    draft?.setEndTime(draft?.workout.startTime ?? Date())
                }
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(Theme.signal)
                .buttonStyle(.plain)
            }
        }

        SectionLabel(text: "note")
        TextField(
            "how it went",
            text: Binding(
                get: { draft?.workout.usernotes ?? "" },
                set: { draft?.setUserNotes($0) }
            ),
            axis: .vertical
        )
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .editableField()
    }

    // MARK: - Exercises

    @ViewBuilder
    private var exerciseSections: some View {
        let groups = draft?.exerciseGroups ?? []
        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
            if group.count > 1 {
                SectionLabel(text: "superset", accent: Theme.signal)
                    .panelRow()
                    .padding(.top, groupIndex == 0 ? 0 : 8)
            }
            ForEach(group) { exercise in
                if isEditing {
                    editableExercise(exercise)
                } else {
                    readOnlyExercise(exercise)
                }
            }
        }
    }

    @ViewBuilder
    private func readOnlyExercise(_ exercise: WorkoutExercise) -> some View {
        SectionLabel(text: exercise.displayName)
            .panelRow()
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((exercise.sets ?? []).enumerated()), id: \.element.id) { index, set in
                    SetSummaryLine(index: index, set: set, unit: unit(for: exercise))
                }
                if let notes = exercise.usernotes, !notes.isEmpty {
                    Text(notes)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
        }
        .panelRow()
    }

    /// The grouped-row treatment the tracker and planner both use, so a lifter
    /// who has edited a plan already knows how to drive this.
    @ViewBuilder
    private func editableExercise(_ exercise: WorkoutExercise) -> some View {
        let sets = exercise.sets ?? []

        LoggedExerciseHeaderRow(
            exercise: exercise,
            onEditNote: { noteTarget = .exercise(exercise.id) },
            onDelete: { draft?.deleteExercise(id: exercise.id) }
        )
        .panelGroupRow(.top)

        ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
            LoggedSetRow(
                number: index + 1,
                set: set,
                unit: unit(for: exercise),
                onChange: { change in draft?.updateSet(id: set.id, change) },
                onEditNote: { noteTarget = .set(set.id) },
                onDelete: { draft?.deleteSet(id: set.id) }
            )
            .panelGroupRow(.middle)
            .swipeActions(edge: .trailing) {
                // Tinted explicitly: `role: .destructive` inherits the app's
                // cyan tint, which would make Delete the same colour as every
                // affirmative control in the app.
                Button("Delete", systemImage: "trash", role: .destructive) {
                    draft?.deleteSet(id: set.id)
                }
                .tint(Theme.alert)
            }
        }

        Button { draft?.addSet(toExerciseWith: exercise.id) } label: {
            Label("Add Set", systemImage: "plus")
                .font(Theme.data(13, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .panelGroupRow(.bottom)
    }

    private var deleteWorkoutButton: some View {
        Button { isConfirmingDelete = true } label: {
            Label("Delete Workout", systemImage: "trash")
                .font(Theme.body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.alert.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.alert)
        .padding(.top, 6)
        .panelRow()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if hasUnsavedChanges {
            ToolbarItem(placement: .navigation) {
                Button {
                    isConfirmingDiscard = true
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if isEditing {
                Button("SAVE") { save() }
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(canSave ? Theme.signal : Theme.inkFaint)
                    .disabled(!canSave)
            } else {
                Button("EDIT") { isEditing = true }
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.signal)
                    .disabled(draft == nil)
            }
        }
    }

    private var hasUnsavedChanges: Bool { draft?.hasUnsavedChanges ?? false }

    private var canSave: Bool {
        guard let draft else { return false }
        return draft.hasUnsavedChanges && draft.canSave
    }

    private var deleteMessage: String {
        let count = draft?.workout.allSets.count ?? 0
        return "\(count) logged set\(count == 1 ? "" : "s") will be removed. This can't be undone."
    }

    // MARK: - Loading and saving

    private func load() {
        // Reloading over unsaved edits would discard them silently — `.task`
        // re-runs on more occasions than a first appearance.
        guard draft == nil else { return }
        do {
            guard let workout = try environment.workouts.fetch(id: workoutID) else {
                loadError = "That workout is no longer in the log."
                return
            }
            draft = LoggedWorkoutDraft(workout)
            loadError = nil
            #if DEBUG
            if LaunchArguments.opensWorkoutEditor { isEditing = true }
            #endif
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard let workout = draft?.workout else { return }
        dismissKeyboard()
        do {
            // `update`, not `save`: the latter takes `blockId` as a parameter
            // and would write NULL, detaching the workout from its block.
            try environment.workouts.update(workout)
            // Per-lift history is derived from the log, so an edited set makes
            // it stale. Recomputed rather than nudged — a table rebuilt from
            // the log can only be stale, never wrong (see `ExerciseStatsStore`).
            if let userID = environment.currentUser?.id {
                try? environment.exerciseStats.rebuild(for: userID)
            }
            // Only after the write succeeds: rebasing on a failed save would
            // report unsaved work as saved.
            draft?.markSaved()
            saveError = nil
            isEditing = false
            onChange?()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func deleteWorkout() {
        do {
            try environment.workouts.delete(id: workoutID)
            if let userID = environment.currentUser?.id {
                try? environment.exerciseStats.rebuild(for: userID)
            }
            onChange?()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Notes

    /// The lifter's own note (`usernotes`), on a set or an exercise. The
    /// programmed note beside it is prescription and stays read-only.
    enum NoteTarget: Identifiable {
        case exercise(UUID)
        case set(UUID)

        var id: UUID {
            switch self {
            case .exercise(let id), .set(let id): id
            }
        }
    }

    private func noteTitle(for target: NoteTarget) -> String {
        switch target {
        case .exercise: "Exercise Note"
        case .set: "Set Note"
        }
    }

    private func prescribedNote(for target: NoteTarget) -> String? {
        switch target {
        case .exercise(let id): draft?.exercise(id: id)?.notes
        case .set(let id): draft?.set(id: id)?.plannedFrom?.notes
        }
    }

    private func noteBinding(for target: NoteTarget) -> Binding<String> {
        Binding(
            get: {
                switch target {
                case .exercise(let id): draft?.exercise(id: id)?.usernotes ?? ""
                case .set(let id): draft?.set(id: id)?.usernotes ?? ""
                }
            },
            set: { newValue in
                let note = newValue.isEmpty ? nil : newValue
                switch target {
                case .exercise(let id):
                    draft?.updateExercise(id: id) { $0.usernotes = note }
                case .set(let id):
                    draft?.updateSet(id: id) { $0.usernotes = note }
                }
            }
        )
    }

    // MARK: - Formatting

    private func unit(for exercise: WorkoutExercise) -> WeightUnit {
        environment.weightUnit(forExerciseID: exercise.exercise.id)
    }

    private var titleText: String {
        guard let start = draft?.workout.startTime else { return "Workout" }
        return start.formatted(.dateTime.month().day().year())
    }

    private func dateText(_ workout: Workout) -> String {
        guard let start = workout.startTime else { return "—" }
        return start.formatted(
            .dateTime.weekday(.abbreviated).month().day().year().hour().minute()
        )
    }

    private func durationText(_ workout: Workout) -> String? {
        guard let start = workout.startTime, let end = workout.endTime else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

// MARK: - Editable rows

private struct LoggedExerciseHeaderRow: View {
    let exercise: WorkoutExercise
    let onEditNote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.displayName)
                    .font(Theme.heading)
                    .foregroundStyle(Theme.ink)
                // The catalog lift underneath, when the plan called it
                // something else. Identity and instruction are different
                // facts and this screen has room for both.
                if exercise.variant != nil {
                    Text(exercise.exercise.name)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button("Edit Note", systemImage: "note.text", action: onEditNote)
                Button("Delete Exercise", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: hasNote ? "note.text" : "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(hasNote ? Theme.signal : Theme.inkFaint)
            }
            .fixedSize()
        }
    }

    private var hasNote: Bool {
        !(exercise.usernotes ?? "").isEmpty
    }
}

/// One logged set, editable.
///
/// Shaped like the tracker's `SetRow` minus the parts that only make sense
/// live: there's no completion checkbox (every set in a finished workout is
/// one that happened) and no rest control (rest is a thing you're waiting
/// through, not a property of a set months later).
private struct LoggedSetRow: View {
    let number: Int
    let set: WorkoutSet
    let unit: WeightUnit
    let onChange: ((inout WorkoutSet) -> Void) -> Void
    let onEditNote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            quantities
            if hasAnnotation { annotation }
        }
        .padding(.vertical, 2)
    }

    private var quantities: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", number))
                .font(Theme.data(13))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            SuggestingNumberField(
                value: repsBinding,
                suggestion: nil,
                fractionDigits: 0,
                label: "reps",
                step: 1,
                onStep: { delta in
                    onChange { $0.reps = max(0, ($0.reps ?? 0) + Int(delta)) }
                }
            )
            .layoutPriority(1)

            Text("×")
                .font(Theme.data(14))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            SuggestingNumberField(
                value: weightBinding,
                suggestion: nil,
                label: "weight",
                // One plate per side, in the unit the plates are marked in.
                step: unit == .pounds ? 2.5 : 1,
                onStep: { delta in
                    let current = self.set.weight?.expressed(in: unit).value ?? 0
                    onChange { $0.weight = Measurement(value: max(0, current + delta), unit: unit.unit) }
                }
            )
            .layoutPriority(2)

            Text(unit.symbol)
                .font(Theme.data(13))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            RPEPicker(
                value: self.set.rpe,
                clearLabel: "not rated",
                onChange: { rpe in onChange { $0.rpe = rpe } }
            )

            menu
        }
    }

    private var menu: some View {
        Menu {
            // Set type is load-bearing rather than a label: `AchievedMaxUpdate`
            // only ever records a max from a `.working` set, so a heavy single
            // mislogged as a warmup is a max that never got recorded.
            Picker("Set Type", selection: typeSelection) {
                ForEach(SetType.allCases, id: \.self) { type in
                    Text(type.rawValue.capitalized).tag(type)
                }
            }
            Button("Edit Note", systemImage: "note.text", action: onEditNote)
            Button("Delete Set", systemImage: "trash", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: hasNote ? "note.text" : "ellipsis")
                .font(.system(size: 14))
                .foregroundStyle(hasNote ? Theme.signal : Theme.inkFaint)
        }
        .fixedSize()
    }

    /// The quiet second line, laid out like the tracker's: indented under the
    /// fields, with the set type on the trailing edge.
    ///
    /// Duration and distance are **shown but not editable**. 75 sets of the
    /// imported history are a walk or a plank, and a row that rendered them as
    /// blank fields would read as data this screen had thrown away. Entering
    /// them is its own round of work — nothing in the app records a cardio set
    /// yet, in the tracker either.
    private var annotation: some View {
        HStack(alignment: .center, spacing: 10) {
            if !timedText.isEmpty {
                Text(timedText)
                    .font(Theme.data(12))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize()
            }
            if let note = self.set.usernotes, !note.isEmpty {
                Text(note)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkFaint)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let type = self.set.type, type != .working {
                Text(type.rawValue.uppercased())
                    .font(Theme.label)
                    .tracking(1.1)
                    .foregroundStyle(Theme.inkFaint)
                    .fixedSize()
            }
        }
        // Clears the set-number column so the line hangs under the fields
        // rather than under the index.
        .padding(.leading, 26)
    }

    private var timedText: String {
        SetSummaryLine.describe(timedPortionOf: self.set)
    }

    private var hasAnnotation: Bool {
        !timedText.isEmpty
            || !(self.set.usernotes ?? "").isEmpty
            || (self.set.type.map { $0 != .working } ?? false)
    }

    private var hasNote: Bool {
        !(self.set.usernotes ?? "").isEmpty
    }

    private var typeSelection: Binding<SetType> {
        Binding(
            get: { self.set.type ?? .working },
            set: { type in onChange { $0.type = type } }
        )
    }

    private var repsBinding: Binding<Double?> {
        Binding(
            get: { self.set.reps.map(Double.init) },
            set: { value in onChange { $0.reps = value.map { Int($0.rounded()) } } }
        )
    }

    /// Reads and writes in the lifter's own unit — a set logged in pounds
    /// converts for display, and editing it writes back in whatever unit is on
    /// screen, which is right: the number shown is the number being committed.
    private var weightBinding: Binding<Double?> {
        Binding(
            get: { self.set.weight?.expressed(in: unit).value },
            set: { value in
                onChange { $0.weight = value.map { Measurement(value: $0, unit: unit.unit) } }
            }
        )
    }
}

/// One logged set, in one line: `2   5 × 225 lb   RPE 8`.
///
/// Also the app's one renderer for a set that has **no reps and no weight** —
/// a walk, a bike interval, a plank. That's a complete record, not an empty
/// one, so it reads as its duration and distance rather than as blanks.
struct SetSummaryLine: View {
    let index: Int
    let set: WorkoutSet
    let unit: WeightUnit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index + 1)")
                .font(Theme.data(13))
                .foregroundStyle(Theme.inkFaint)
                .frame(width: 18, alignment: .leading)
            Text(SetSummaryLine.describe(set, in: unit))
                .font(Theme.data(15, weight: .medium))
                .foregroundStyle(Theme.ink)
            if let type = set.type, type != .working {
                Chip(text: type.rawValue, color: Theme.inkFaint)
            }
            Spacer(minLength: 8)
            if let rpe = set.rpe {
                Text("RPE \(rpe.rpeDescription)")
                    .font(Theme.data(13))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    /// What a set says on one line. Shared with the exercise-history screen so
    /// the two can't describe the same set differently.
    static func describe(_ set: WorkoutSet, in unit: WeightUnit) -> String {
        var parts: [String] = []

        if let reps = set.reps {
            if let weight = set.weight {
                parts.append("\(reps) × \(weight.liftedDescription(in: unit))")
            } else {
                parts.append("\(reps) reps")
            }
        } else if let weight = set.weight {
            parts.append(weight.liftedDescription(in: unit))
        }

        let timed = describe(timedPortionOf: set)
        if !timed.isEmpty { parts.append(timed) }

        // An honest empty state rather than a blank line: a set with nothing
        // recorded is a real row in the log and should say so (Core Tenets §10).
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Just the time-and-distance half — `20:00 · 2.4 mi`, or empty when the
    /// set is ordinary strength work.
    static func describe(timedPortionOf set: WorkoutSet) -> String {
        var parts: [String] = []
        if let duration = set.duration {
            parts.append(clock(duration))
        }
        if let distance = set.distance {
            let number = distance.value.formatted(.number.precision(.fractionLength(0...2)))
            parts.append("\(number) \(distance.unit.symbol)")
        }
        return parts.joined(separator: " · ")
    }

    private static func clock(_ duration: Measurement<UnitDuration>) -> String {
        let seconds = Int(duration.converted(to: .seconds).value.rounded())
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

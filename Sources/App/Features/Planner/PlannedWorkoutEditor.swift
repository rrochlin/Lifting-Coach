import Foundation
import SwiftUI
import LiftingCoachModel

/// Authoring one programmed day.
///
/// Deliberately shaped like the Workout Tracker — same grouped rows, same
/// always-visible quantity fields, same swipe-to-delete on the *set* row and
/// exercise-level actions behind the header's menu. A lifter who has used the
/// tracker already knows how to drive this.
///
/// The one behavioral difference is when writes happen. The tracker saves after
/// every mutation because a session the OS kills mid-workout must be
/// recoverable. Planning is deliberate authoring, so edits accumulate in a
/// `PlannedWorkoutDraft` and land only on **Save** — with a confirmation on the
/// way out if anything is unsaved.
struct PlannedWorkoutEditor: View {
    let model: PlannerModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlannedWorkoutDraft
    @State private var isPickingExercise = false
    @State private var isConfirmingDiscard = false
    @State private var noteTarget: NoteTarget?
    @State private var editMode: EditMode = .inactive

    init(model: PlannerModel, workout: PlannedWorkout) {
        self.model = model
        _draft = State(initialValue: PlannedWorkoutDraft(workout))
    }

    var body: some View {
        List {
            dayLabelSection
            exerciseSections
            addExerciseButton
        }
        .listStyle(.plain)
        .screenGround()
        .environment(\.editMode, $editMode)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Only while dirty: with nothing to lose, the system's back gesture and
        // button should work exactly as they do everywhere else.
        .navigationBarBackButtonHidden(draft.hasUnsavedChanges)
        .toolbar { toolbar }
        .sheet(isPresented: $isPickingExercise) {
            PlannerExercisePicker { exercise in
                draft.addExercise(exercise)
            }
        }
        .sheet(item: $noteTarget) { target in
            PlannerNoteSheet(title: noteTitle(for: target), note: noteBinding(for: target))
        }
        .themedConfirm(
            isPresented: $isConfirmingDiscard,
            title: "Discard changes?",
            message: "This day's edits haven't been saved.",
            confirmLabel: "Discard",
            cancelLabel: "Keep Editing",
            onConfirm: { dismiss() }
        )
    }

    private var title: String {
        draft.workout.date?.formatted(date: .abbreviated, time: .omitted) ?? "Workout"
    }

    // MARK: Sections

    /// The day's own label ("Week 5 Fri — Deadlift + Bench"), which is also what
    /// every list of days shows as its title.
    private var dayLabelSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "day label")
                TextField(
                    "e.g. Week 5 Fri — Deadlift + Bench",
                    text: Binding(
                        get: { draft.workout.notes ?? "" },
                        set: { draft.setNotes($0) }
                    ),
                    axis: .vertical
                )
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
            }
        }
        .panelRow()
    }

    @ViewBuilder
    private var exerciseSections: some View {
        let groups = draft.exerciseGroups
        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
            if group.count > 1 {
                SectionLabel(text: "superset", accent: Theme.signal)
                    .panelRow()
                    .padding(.top, groupIndex == 0 ? 0 : 8)
            }
            ForEach(group) { exercise in
                exerciseRows(exercise)
            }
        }
        // Whole groups move together, matching the tracker's granularity.
        .onMove { offsets, destination in
            guard let source = offsets.first else { return }
            draft.moveGroup(from: source, to: destination)
        }
    }

    @ViewBuilder
    private func exerciseRows(_ exercise: PlannedExercise) -> some View {
        let sets = exercise.sets ?? []
        // Rest is written per exercise; when the sets disagree there's no single
        // value to show in the header, so each row carries its own instead.
        let uniformRest = draft.uniformRestTime(forExerciseWith: exercise.id)
        let restIsMixed = uniformRest == nil && sets.contains { $0.restTime != nil }

        PlannedExerciseHeaderRow(
            exercise: exercise,
            restSeconds: uniformRest,
            restIsMixed: restIsMixed,
            onEffortChange: { effort in
                draft.updateExercise(id: exercise.id) { $0.effort = effort }
            },
            onRestChange: { seconds in
                draft.setRestTime(seconds, forExerciseWith: exercise.id)
            },
            onEditNote: { noteTarget = .exercise(exercise.id) },
            onDelete: { draft.deleteExercise(id: exercise.id) }
        )
        .panelGroupRow(.top)

        ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
            PlannedSetRow(
                number: index + 1,
                set: set,
                inheritedEffort: exercise.effort,
                resolvedWeight: resolvedWeight(for: set, exercise: exercise.exercise),
                resolvedRest: model.restTime(for: set),
                onChange: { change in draft.updateSet(id: set.id, change) },
                onEditNote: { noteTarget = .set(set.id) },
                onDelete: { draft.deleteSet(id: set.id) }
            )
            .panelGroupRow(.middle)
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    draft.deleteSet(id: set.id)
                }
            }
        }
        .onMove { offsets, destination in
            guard let source = offsets.first else { return }
            draft.moveSet(from: source, to: destination, within: exercise.id)
        }

        // Its own row, and the only thing that adds a set. Previously every
        // button in an exercise shared one List row, so the whole row — the
        // exercise title included — fired "Add Set".
        Button { draft.addSet(toExerciseWith: exercise.id) } label: {
            Label("Add Set", systemImage: "plus")
                .font(Theme.data(11, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .panelGroupRow(.bottom)
    }

    private var addExerciseButton: some View {
        Button { isPickingExercise = true } label: {
            Label("Add Exercise", systemImage: "plus")
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

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if draft.hasUnsavedChanges {
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
            EditButton()
        }
        ToolbarItem(placement: .primaryAction) {
            Button("SAVE") { save() }
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(draft.hasUnsavedChanges ? Theme.signal : Theme.inkFaint)
                .disabled(!draft.hasUnsavedChanges)
        }
    }

    private func save() {
        // saveDraft only rebases the draft once the write succeeds, so a failed
        // save leaves the edits on screen with the error in the header rather
        // than silently dropping them.
        model.saveDraft(&draft)
    }

    // MARK: Resolution

    private func resolvedWeight(for set: PlannedSet, exercise: Exercise) -> Measurement<UnitMass>? {
        guard let load = set.load else { return nil }
        return model.resolvedWeight(for: load, exercise: exercise)
    }

    // MARK: Notes

    /// Which item the note sheet is open on. These are the *programmed* notes
    /// (`PlannedSet.notes`) — the lifter's own `usernotes` are logged during a
    /// workout, not authored here.
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

    private func noteBinding(for target: NoteTarget) -> Binding<String> {
        Binding(
            get: {
                switch target {
                case .exercise(let id): draft.exercise(id: id)?.notes ?? ""
                case .set(let id): draft.set(id: id)?.notes ?? ""
                }
            },
            set: { newValue in
                let note = newValue.isEmpty ? nil : newValue
                switch target {
                case .exercise(let id):
                    draft.updateExercise(id: id) { $0.notes = note }
                case .set(let id):
                    draft.updateSet(id: id) { $0.notes = note }
                }
            }
        )
    }
}

// MARK: - Exercise header

private struct PlannedExerciseHeaderRow: View {
    let exercise: PlannedExercise
    let restSeconds: Int?
    let restIsMixed: Bool
    let onEffortChange: (EffortTarget?) -> Void
    let onRestChange: (Int?) -> Void
    let onEditNote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(exercise.displayName)
                    .font(Theme.heading)
                    .foregroundStyle(Theme.ink)
                    // Program names are long and descriptive ("Deadlift — heavy
                    // (straight bar)"); one line truncates the part that tells
                    // it apart from the other three deadlift days.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if exercise.exercise.isOpenChoice {
                    Chip(text: "your choice", color: Theme.inkMuted)
                }
                Spacer(minLength: 4)
                if !(exercise.notes ?? "").isEmpty {
                    Image(systemName: "note.text")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.signal)
                        .fixedSize()
                }
                Menu {
                    Button("Edit Note", systemImage: "note.text", action: onEditNote)
                    Button("Delete Exercise", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.inkMuted)
                }
                .fixedSize()
            }

            // The catalog lift underneath the plan's own wording. Worth a line
            // here: it's the identity a %-of-max resolves against and where an
            // achieved max lands, and this is the screen where you'd want to
            // know you picked the right one.
            if exercise.variant != nil {
                Text(exercise.exercise.name)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkFaint)
                    .lineLimit(1)
            }

            // Both are exercise-level instructions — "5×2 @ RPE 7, 3 minutes"
            // is written once, not copied onto every set.
            HStack(spacing: 14) {
                RPEPicker(
                    value: exercise.effort?.rpe,
                    label: "RPE",
                    clearLabel: "none",
                    onChange: { rpe in onEffortChange(rpe.map { EffortTarget(rpe: $0) }) }
                )
                RestMenu(seconds: restSeconds, isMixed: restIsMixed, onChange: onRestChange)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Set row

/// One prescribed set, with every quantity visible and directly editable —
/// same contract as the tracker's set row, and width-agnostic the same way:
/// nothing has a fixed width, the two number fields share free space by layout
/// priority, and every label is `fixedSize` so iOS truncates a field rather
/// than rendering "lb" as "l".
private struct PlannedSetRow: View {
    let number: Int
    let set: PlannedSet
    /// The exercise's effort target, shown greyed when this set doesn't
    /// override it — so an inherited RPE 7 is visible on the row rather than
    /// looking like nothing was prescribed.
    let inheritedEffort: EffortTarget?
    let resolvedWeight: Measurement<UnitMass>?
    /// Rest this set actually resolves to, its own value or the block's default
    /// — shown either way, so "how long here?" never needs a second screen.
    let resolvedRest: Int
    let onChange: ((inout PlannedSet) -> Void) -> Void
    let onEditNote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            quantities
            if annotationText != nil {
                annotations
            }
            rest
        }
        .padding(.vertical, 2)
    }

    /// Whatever the controls above don't already say.
    private var annotations: some View {
        HStack(alignment: .center, spacing: 10) {
            if let annotationText {
                Text(annotationText)
                    .font(Theme.data(10))
                    .foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
    }

    /// The same `RestControl` the tracker puts under a set — there is one rest
    /// control in this app, and authoring a rest and counting one down are the
    /// same idea seen at different times.
    ///
    /// Rest is authored per set here, matching where it's stored
    /// (`PlannedSet.restTime`). The exercise header still writes all of them at
    /// once, because "three minutes on squats" is usually one instruction — but
    /// a day that wants three minutes before the top single and ninety seconds
    /// after can say so.
    private var rest: some View {
        RestControl(
            mode: .prescription(seconds: resolvedRest, isExplicit: self.set.restTime != nil),
            onSet: { seconds in onChange { $0.restTime = seconds } },
            actionLabel: self.set.restTime == nil ? nil : "use block default",
            onAction: self.set.restTime == nil ? nil : { onChange { $0.restTime = nil } }
        )
        .padding(.leading, 26)
    }

    private var quantities: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", number))
                .font(Theme.data(11))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            numberField(value: repsBinding, format: .number)
                .layoutPriority(1)

            Text("×")
                .font(Theme.data(12))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            numberField(value: loadBinding, format: .number.precision(.fractionLength(0...2)))
                .layoutPriority(2)
                .opacity(self.set.load == nil ? 0.45 : 1)

            LoadModeMenu(load: self.set.load) { newLoad in
                onChange { $0.load = newLoad }
            }
            .fixedSize()

            RPEPicker(
                value: self.set.effort?.rpe,
                placeholder: inheritedEffort?.rpe.rpeDescription,
                // "@7" rather than a bare 7 — the same shorthand the block
                // overview uses, so the number beside "% goal" can't be read as
                // part of the load.
                prefix: "@",
                clearLabel: inheritedEffort.map { "inherit (\($0.rpe.rpeDescription))" } ?? "none",
                onChange: { rpe in
                    onChange { $0.effort = rpe.map { EffortTarget(rpe: $0) } }
                }
            )

            Menu {
                Picker("Set Type", selection: typeBinding) {
                    ForEach(SetType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                Button("Edit Note", systemImage: "note.text", action: onEditNote)
                Button("Delete Set", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: hasNote ? "note.text" : "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(hasNote ? Theme.signal : Theme.inkFaint)
            }
            .fixedSize()
        }
    }

    /// The quiet second line: what a percentage actually works out to, plus
    /// anything the row's controls don't already say.
    private var annotationText: String? {
        var parts: [String] = []
        // Only for percentages — an absolute load is already the number in the
        // field, and echoing it would just be noise.
        if case .percentOf = self.set.load, let resolvedWeight {
            parts.append("→ \(resolvedWeight.liftedDescription)")
        }
        if case .percentOf = self.set.load, resolvedWeight == nil {
            // The referenced max isn't on record. Say so rather than showing a
            // blank where a weight belongs (Core Tenets §10).
            parts.append("no max on record")
        }
        if let type = self.set.type, type != .working {
            parts.append(type.rawValue.uppercased())
        }
        if let note = self.set.notes, !note.isEmpty {
            parts.append(note)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

    private func numberField<F: ParseableFormatStyle>(
        value: Binding<F.FormatInput>,
        format: F
    ) -> some View where F.FormatOutput == String {
        TextField("", value: value, format: format)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .font(Theme.data(15))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .frame(minWidth: 30, maxWidth: 72)
            // Outlined like the tracker's fields — same contract, same look.
            .editableField(isActive: true)
    }

    // `self.` throughout: a bare `set` opening a computed property's body parses
    // as the start of a setter declaration.
    private var hasNote: Bool { !(self.set.notes ?? "").isEmpty }

    private var repsBinding: Binding<Int> {
        Binding(
            get: { self.set.reps ?? 0 },
            set: { reps in onChange { $0.reps = reps } }
        )
    }

    private var typeBinding: Binding<SetType> {
        Binding(
            get: { self.set.type ?? .working },
            set: { type in onChange { $0.type = type } }
        )
    }

    /// The number field's meaning follows the load's mode: a percentage reads
    /// as 72.5, an absolute weight as 265. Typing into an unprescribed set
    /// creates an absolute load — the mode menu beside it is how you say you
    /// meant a percentage instead.
    private var loadBinding: Binding<Double> {
        Binding(
            get: {
                switch self.set.load {
                case .absolute(let weight): weight.value
                case .percentOf(let percent, _): (percent * 100).rounded(toPlaces: 1)
                case nil: 0
                }
            },
            set: { newValue in
                onChange { set in
                    switch set.load {
                    case .percentOf(_, let reference):
                        set.load = .percentOf(newValue / 100, of: reference)
                    case .absolute(let weight):
                        set.load = .absolute(Measurement(value: newValue, unit: weight.unit))
                    case nil:
                        set.load = .absolute(Measurement(value: newValue, unit: .pounds))
                    }
                }
            }
        )
    }
}

private extension Double {
    /// Keeps 0.725 → 72.5 rather than 72.50000000000001 in the text field.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

// MARK: - Compact controls

/// The load's mode: absolute weight, a percentage of one of the lifter's
/// maxes, or nothing prescribed at all.
///
/// `.theoretical` is deliberately absent. It's a real `MaxReference`, but it
/// resolves to `nil` by design until the estimation model exists — offering it
/// here would let someone author a prescription that can never produce a
/// weight (Core Tenets §6).
private struct LoadModeMenu: View {
    let load: LoadPrescription?
    let onChange: (LoadPrescription?) -> Void

    var body: some View {
        Menu {
            Button("lb") { switchTo(.absolute(.pounds)) }
            Button("kg") { switchTo(.absolute(.kilograms)) }
            Divider()
            Button("% of goal max") { switchTo(.percent(.goal)) }
            Button("% of achieved max") { switchTo(.percent(.achieved)) }
            Divider()
            Button("No load", role: .destructive) { switchTo(.cleared) }
        } label: {
            // The unit sat here as bare text, which made the one control that
            // says "this number is pounds, not a percentage" look like a label
            // on the field beside it. A caret is the whole fix.
            HStack(spacing: 3) {
                Text(label)
                    .font(Theme.data(11, weight: .medium))
                FieldCaret(color: load == nil ? Theme.inkFaint : Theme.inkMuted)
            }
            .foregroundStyle(load == nil ? Theme.inkFaint : Theme.inkMuted)
            .fixedSize()
        }
    }

    private var label: String {
        switch load {
        case .absolute(let weight): weight.unit.symbol
        case .percentOf(_, let reference): "% \(reference.rawValue.prefix(4))"
        case nil: "—"
        }
    }

    private enum Mode {
        case absolute(UnitMass)
        case percent(MaxReference)
        case cleared
    }

    /// Switching modes keeps the number only where it still means something.
    /// 265 lb reinterpreted as "265% of goal" would be nonsense, so a switch
    /// across the two axes starts from a sane default instead; switching
    /// lb↔kg or goal↔achieved keeps what's there.
    private func switchTo(_ mode: Mode) {
        switch mode {
        case .absolute(let unit):
            if case .absolute(let weight) = load {
                onChange(.absolute(Measurement(value: weight.value, unit: unit)))
            } else {
                onChange(.absolute(Measurement(value: 0, unit: unit)))
            }
        case .percent(let reference):
            if case .percentOf(let percent, _) = load {
                onChange(.percentOf(percent, of: reference))
            } else {
                onChange(.percentOf(0.7, of: reference))
            }
        case .cleared:
            onChange(nil)
        }
    }
}

/// Rest for a whole exercise at once — writes every one of its sets. The sets
/// each carry their own `RestControl` for the cases that differ.
private struct RestMenu: View {
    let seconds: Int?
    /// The exercise's sets don't agree, so there's no single value to show.
    let isMixed: Bool
    let onChange: (Int?) -> Void

    var body: some View {
        Menu {
            Button("block default") { onChange(nil) }
            Divider()
            ForEach(options, id: \.self) { value in
                Button(value.restClockDescription) { onChange(value) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("REST")
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.inkMuted)
                // Same field as `RPEPicker` wears, so the header's controls
                // controls on this header read as one family of editable
                // values rather than one field and two labels.
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(seconds == nil ? Theme.inkFaint : Theme.ink)
                    Text(displayValue)
                        .font(Theme.data(13, weight: .medium))
                        .foregroundStyle(seconds == nil ? Theme.inkFaint : Theme.ink)
                    FieldCaret(color: seconds == nil ? Theme.inkFaint : Theme.inkMuted)
                }
                .editableField(isActive: seconds != nil)
            }
            .fixedSize()
        }
    }

    private var displayValue: String {
        if let seconds { return seconds.restClockDescription }
        return isMixed ? "mixed" : "—"
    }

    private var options: [Int] { [30, 45, 60, 90, 120, 150, 180, 240, 300] }
}

// MARK: - Note sheet

/// The programmed note — "work up, stop at 9", tempo, a pause cue. Distinct
/// from the lifter's own `usernotes`, which are written during a workout.
private struct PlannerNoteSheet: View {
    let title: String
    @Binding var note: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel(text: "programmed note", accent: Theme.signal)
                TextEditor(text: $note)
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
            .navigationTitle(title)
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

// MARK: - Exercise picker

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
            .searchable(text: $query)
            .navigationTitle("Add Exercise")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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

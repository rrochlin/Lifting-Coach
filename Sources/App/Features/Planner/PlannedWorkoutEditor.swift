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
    /// The one set whose rest editor is open. Owned here, not in the control:
    /// the editor is a row of its own, so opening it never resizes a row that's
    /// already on screen. See `RestControl`.
    @State private var expandedRest: UUID?
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
            ExercisePicker { exercise in
                draft.addExercise(exercise)
            }
        }
        .sheet(item: $noteTarget) { target in
            NoteSheet(
                title: noteTitle(for: target),
                editorLabel: "programmed note",
                note: noteBinding(for: target)
            )
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

        // "4×5 @ 225" in one statement. The block overview has always read a
        // plan back this way; this is the same shape on the way in.
        BulkSetRow(
            working: sets.filter { ($0.type ?? .working) == .working },
            onApply: { count, reps, load in
                draft.setWorkingSets(
                    count: count, reps: reps, load: load, toExerciseWith: exercise.id
                )
            }
        )
        .panelGroupRow(.middle)

        ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
            PlannedSetRow(
                number: index + 1,
                set: set,
                inheritedEffort: exercise.effort,
                resolvedWeight: resolvedWeight(for: set, exercise: exercise.exercise),
                resolvedRest: model.restTime(for: set),
                onChange: { change in draft.updateSet(id: set.id, change) },
                onEditNote: { noteTarget = .set(set.id) },
                onDelete: { draft.deleteSet(id: set.id) },
                isRestExpanded: expandedRest == set.id,
                onToggleRest: { expandedRest = expandedRest == set.id ? nil : set.id }
            )
            .panelGroupRow(.middle)
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    draft.deleteSet(id: set.id)
                }
                .tint(Theme.alert)
            }

            if expandedRest == set.id {
                RestEditor(
                    mode: .prescription(
                        seconds: model.restTime(for: set),
                        isExplicit: set.restTime != nil
                    ),
                    onSet: { seconds in
                        draft.updateSet(id: set.id) { $0.restTime = seconds }
                    },
                    actionLabel: set.restTime == nil ? nil : "use block default",
                    onAction: set.restTime == nil
                        ? nil
                        : { draft.updateSet(id: set.id) { $0.restTime = nil } }
                )
                .padding(.leading, 26)
                .panelGroupRow(.middle)
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
                .font(Theme.data(13, weight: .medium))
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
                        .font(.system(size: 13))
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
// MARK: - Bulk set authoring

/// `SETS 4 × REPS 5 @ 225 lb → APPLY` — the whole prescription for an
/// exercise, written once.
///
/// **Why this exists.** Authoring was one row at a time, and a program is not
/// written that way: "4×5 @ 225" is a single thought, and entering it meant
/// four taps of Add Set and twelve fields. Reported as "we should be able to
/// program sets x weight x reps to make writing easier if we're doing the same
/// weight for multiple sets".
///
/// **It doesn't replace the per-set rows, and mustn't.** Back-off sets,
/// ascending ramps and a per-set RPE are all real programming, and they're
/// exactly what a uniform control can't say. This writes the common case and
/// the rows below stay authoritative for everything else — which is also why
/// the fields here *seed themselves from the sets that already exist*: open a
/// day already written as 3×5 @ 225 and the control reads 3, 5, 225, so
/// pressing APPLY with one number changed is an edit rather than a surprise.
///
/// Working sets only (`setWorkingSets` is where that rule lives): a bulk
/// prescription is never an instruction to delete a warmup ramp.
private struct BulkSetRow: View {
    let working: [PlannedSet]
    let onApply: (Int, Int?, LoadPrescription?) -> Void

    @State private var count = 0
    @State private var reps = 0
    @State private var load = 0.0

    var body: some View {
        HStack(spacing: 6) {
            Text("ALL")
                .font(Theme.label)
                .tracking(1.4)
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            NumberField(
                value: $count, format: .number, label: "sets",
                font: Theme.data(15), step: 1,
                onStep: { delta in count = max(0, count + Int(delta)) }
            )
            Text("×")
                .font(Theme.data(14))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()
            NumberField(
                value: $reps, format: .number, label: "reps",
                font: Theme.data(15), step: 1,
                onStep: { delta in reps = max(0, reps + Int(delta)) }
            )
            NumberField(
                value: $load,
                format: .number.precision(.fractionLength(0...2)),
                label: loadLabel,
                font: Theme.data(15), step: step,
                onStep: { delta in load = max(0, load + delta) }
            )
            // The number alone can't say whether it's pounds or a percentage,
            // and this row has no mode menu of its own to imply it — it follows
            // whatever the sets are already written in.
            Text(loadLabel)
                .font(Theme.data(13))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            Button {
                onApply(count, reps > 0 ? reps : nil, prescription)
            } label: {
                Text("APPLY")
                    .font(Theme.label)
                    .tracking(1.4)
                    .foregroundStyle(canApply ? Theme.signal : Theme.inkFaint)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(minHeight: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(
                                canApply ? Theme.signal.opacity(0.55) : Theme.hairline,
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canApply)
        }
        .padding(.leading, 26)
        .onAppear(perform: seed)
        // Re-seeds when the sets change underneath — deleting a row leaves this
        // reading a count that is no longer true otherwise, and a stale number
        // beside an APPLY button is a trap.
        .onChange(of: working.count) { seed() }
    }

    /// Clearing every working set is `setWorkingSets`' business and legal, but
    /// it isn't something to offer behind a button labelled APPLY — deleting
    /// the rows says it deliberately.
    private var canApply: Bool { count > 0 }

    /// Seeded from what's already written, so this reads as the current
    /// prescription rather than as blanks: open a day written as 3×5 @ 225 and
    /// pressing APPLY with one number changed is an edit, not a surprise. Taken
    /// from the first working set — where they disagree the rows below are the
    /// truth, and this is the control that would make them agree.
    private func seed() {
        count = working.count
        reps = working.first?.reps ?? 0
        switch working.first?.load {
        case .absolute(let weight): load = weight.value
        case .percentOf(let percent, _): load = (percent * 100).rounded(toPlaces: 1)
        case nil: load = 0
        }
    }

    /// Whatever the sets are already written in — an authored absolute load
    /// keeps the unit it was written in, and this must not quietly convert one.
    private var unit: UnitMass {
        if case .absolute(let weight) = working.first?.load { return weight.unit }
        return .pounds
    }

    private var step: Double {
        if case .percentOf = working.first?.load { return 2.5 }
        return unit == .kilograms ? 1 : 2.5
    }

    private var loadLabel: String {
        if case .percentOf = working.first?.load { return "%" }
        return unit.symbol
    }

    /// Carries the *mode* the sets already use, so applying to a percentage
    /// prescription writes a percentage. Changing the mode is still the per-set
    /// menu's job — offering it twice is how two controls drift apart.
    private var prescription: LoadPrescription? {
        guard load > 0 else { return nil }
        if case .percentOf(_, let reference) = working.first?.load {
            return .percentOf(load / 100, of: reference)
        }
        return .absolute(Measurement(value: load, unit: unit))
    }
}

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
    /// Whether the day editor is showing `RestEditor` under this row.
    let isRestExpanded: Bool
    let onToggleRest: () -> Void

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
                    .font(Theme.data(12))
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
            isExpanded: isRestExpanded,
            onToggleExpanded: onToggleRest,
            onSet: { seconds in onChange { $0.restTime = seconds } }
        )
        .padding(.leading, 26)
    }

    private var quantities: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", number))
                .font(Theme.data(13))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            NumberField(
                value: repsBinding,
                format: .number,
                label: "reps",
                font: Theme.data(15),
                step: 1,
                onStep: { delta in
                    repsBinding.wrappedValue = max(0, repsBinding.wrappedValue + Int(delta))
                }
            )
            .layoutPriority(1)

            Text("×")
                .font(Theme.data(14))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            NumberField(
                value: loadBinding,
                format: .number.precision(.fractionLength(0...2)),
                label: loadLabel,
                font: Theme.data(15),
                step: loadStep,
                onStep: { delta in
                    loadBinding.wrappedValue = max(0, loadBinding.wrappedValue + delta)
                }
            )
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
                    .font(.system(size: 14))
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

    /// The step this load moves in, in whatever the field currently means: one
    /// plate per side for an absolute weight, 2.5 points for a percentage.
    private var loadStep: Double {
        switch self.set.load {
        case .absolute(let weight): weight.unit == .kilograms ? 1 : 2.5
        case .percentOf, nil: 2.5
        }
    }

    /// Names the field on the keyboard bar in the terms it's being written in,
    /// since the mode menu that says which is off screen behind the keyboard.
    private var loadLabel: String {
        switch self.set.load {
        case .absolute(let weight): weight.unit.symbol
        case .percentOf: "%"
        case nil: "load"
        }
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
                    .font(Theme.data(13, weight: .medium))
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

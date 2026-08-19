import SwiftUI
import LiftingCoachModel

/// A training block's own settings, editable after it has started.
///
/// The gap this closes: a block was only ever configured at the moment it was
/// created, so a program loaded onto the wrong start date could not be moved.
/// That's the common case rather than an edge one — the owner's real block was
/// five weeks in on paper and week 1 day 1 in the app, with no way to say so.
///
/// **Changing the start date offers to move the whole program with it, and the
/// lifter chooses.** Both readings are legitimate and they're different edits:
/// rescheduling the training (the days move, the program's shape is preserved)
/// versus correcting a date that was recorded wrong (the days stay, only the
/// block's own start is restated). Doing either silently would be the app
/// deciding what the lifter meant (Core Tenets §1), so the toggle is on screen
/// and the consequence is spelled out before it lands.
///
/// Draft-shaped like the rest of the planner: edits accumulate in this view's
/// own state and land on an explicit SAVE, with a confirm on the way out. The
/// tracker's save-every-mutation rule is for a workout the OS might kill; this
/// is authoring, and a half-dragged date shouldn't become the schedule.
///
/// The block's `journal` is deliberately absent. It round-trips through
/// persistence and nothing in the app displays it, so a field here would write
/// text the lifter could never read back.
struct BlockSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// What's on disk. Every edit is expressed as a transform of this, so the
    /// "move the program" toggle can be flipped back and forth without the
    /// shift compounding.
    let original: WorkoutBlock
    let calendar: Calendar
    let onSave: (WorkoutBlock) -> Void
    let onDelete: () -> Void

    @State private var name: String = ""
    @State private var startDate = Date()
    @State private var movesProgram = true
    @State private var weeks = 6
    @State private var restTimes: [SetType: Int] = [:]

    @State private var isConfirmingMove = false
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationStack {
            List {
                nameSection
                scheduleSection
                lengthSection
                restSection
                deleteSection
            }
            .listStyle(.plain)
            .screenGround()
            .navigationTitle("Block Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .onAppear(perform: loadFromBlock)
        }
        .tint(Theme.signal)
        .themedConfirm(
            isPresented: $isConfirmingMove,
            title: "Move the program",
            message: moveMessage,
            confirmLabel: "Move",
            confirmRole: nil,
            onConfirm: commit
        )
        .themedConfirm(
            isPresented: $isConfirmingDiscard,
            title: "Discard changes",
            message: "The block keeps its current settings.",
            confirmLabel: "Discard",
            onConfirm: { dismiss() }
        )
        .themedConfirm(
            isPresented: $isConfirmingDelete,
            title: "Delete this block",
            message: deleteMessage,
            confirmLabel: "Delete",
            onConfirm: {
                onDelete()
                dismiss()
            }
        )
    }

    // MARK: - The edited block

    /// The block as the current inputs describe it.
    ///
    /// Recomputed from `original` every time rather than mutated in place: the
    /// program shift is a transform, and applying it to an already-shifted copy
    /// would move the days twice the moment anything else on the screen changed.
    private var edited: WorkoutBlock {
        var block: WorkoutBlock
        if movesProgram {
            block = original.rescheduled(to: startDate, calendar: calendar)
        } else {
            block = original
            block.startDate = calendar.startOfDay(for: startDate)
        }
        block = block.withLength(weeks: weeks, calendar: calendar)
        block.notes = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        block.defaultRestTimes = restTimes.isEmpty ? nil : restTimes
        return block
    }

    private var hasChanges: Bool { edited != original }

    /// How far the program moves, in days. `0` when the days stay put — which
    /// is also the case when the lifter turned the toggle off.
    private var shiftInDays: Int {
        guard movesProgram,
              let anchor = original.scheduleAnchor(calendar: calendar),
              let offset = calendar.dateComponents(
                  [.day],
                  from: anchor,
                  to: calendar.startOfDay(for: startDate)
              ).day
        else { return 0 }
        return offset
    }

    private var programmedDayCount: Int {
        (original.program ?? [:]).values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "block")
                TextField("Goal for this block", text: $name, axis: .vertical)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .textFieldStyle(.plain)
            }
        }
        .panelRow()
    }

    private var scheduleSection: some View {
        Panel(accent: shiftInDays == 0 ? Theme.hairline : Theme.signal.opacity(0.5)) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "schedule")

                DatePicker(selection: $startDate, displayedComponents: .date) {
                    Text("STARTS")
                        .font(Theme.label)
                        .tracking(1.2)
                        .foregroundStyle(Theme.inkMuted)
                }
                .datePickerStyle(.compact)

                Toggle(isOn: $movesProgram) {
                    Text("Move the program with it")
                        .font(Theme.body)
                        .foregroundStyle(Theme.ink)
                }
                .tint(Theme.signal)

                Text(scheduleFootnote)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Rectangle().fill(Theme.hairline).frame(height: 1)

                // The readout that makes this screen worth opening: what week
                // today lands in once the change is saved. The lifter knows
                // which week they're actually on; this is how they dial the
                // date until the app agrees.
                Readout(
                    label: "today",
                    value: todayDescription,
                    accent: Theme.live,
                    size: 17
                )
                if let range = programRange {
                    Readout(label: "program", value: range, accent: Theme.inkMuted, size: 14)
                }
            }
        }
        .panelRow()
    }

    private var lengthSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "length")
                Stepper(value: $weeks, in: 1...52) {
                    Readout(label: "weeks", value: "\(weeks)", accent: Theme.ink, size: 17)
                }
                if let end = edited.endDate {
                    Readout(
                        label: "ends",
                        value: end.formatted(date: .abbreviated, time: .omitted),
                        accent: Theme.inkMuted,
                        size: 14
                    )
                }
                Text("A planned end, not a boundary — a block that runs long keeps counting past it rather than disappearing.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelRow()
    }

    private var restSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "rest defaults")
                ForEach(SetType.allCases, id: \.self) { type in
                    // Laid out as a `Readout` — label left, value right — so
                    // the three line up in a column the way every other stack
                    // of values in the app does.
                    HStack {
                        Text(type.rawValue.uppercased())
                            .font(Theme.label)
                            .tracking(1.2)
                            .foregroundStyle(Theme.inkMuted)
                        Spacer(minLength: 12)
                        RestMenu(
                            seconds: restTimes[type],
                            label: nil,
                            clearLabel: "app default (2:00)"
                        ) { seconds in
                            if let seconds {
                                restTimes[type] = seconds
                            } else {
                                restTimes.removeValue(forKey: type)
                            }
                        }
                    }
                }
                Text("What a set rests for when it doesn't say. A prescription written on the set itself still wins, and so does a rest the lifter sets at the rack.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelRow()
    }

    private var deleteSection: some View {
        Button { isConfirmingDelete = true } label: {
            Label("Delete Block", systemImage: "trash")
                .font(Theme.body)
                .foregroundStyle(Theme.alert)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.alert.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .panelRow()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("CANCEL") {
                if hasChanges {
                    isConfirmingDiscard = true
                } else {
                    dismiss()
                }
            }
            .font(Theme.label)
            .tracking(1.2)
            .foregroundStyle(Theme.inkMuted)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("SAVE") { save() }
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(hasChanges ? Theme.signal : Theme.inkFaint)
                .disabled(!hasChanges)
        }
    }

    // MARK: - Actions

    private func loadFromBlock() {
        name = original.notes ?? ""
        startDate = original.startDate ?? Date()
        weeks = original.plannedWeeks(calendar: calendar) ?? 6
        restTimes = original.defaultRestTimes ?? [:]
    }

    /// Moving a program is the one edit here that reaches past the block's own
    /// row, so it asks first and names what it will do. Everything else lands
    /// on SAVE directly — a renamed block needs no ceremony.
    private func save() {
        if shiftInDays != 0, programmedDayCount > 0 {
            isConfirmingMove = true
        } else {
            commit()
        }
    }

    private func commit() {
        onSave(edited)
        dismiss()
    }

    // MARK: - Copy

    private var scheduleFootnote: String {
        if movesProgram {
            if shiftInDays == 0 {
                return "Every programmed day moves with the start date, so the program keeps its shape."
            }
            let direction = shiftInDays < 0 ? "earlier" : "later"
            return "\(programmedDayCount) programmed days move \(abs(shiftInDays)) days \(direction). Logged workouts stay where they happened."
        }
        return "Only the block's start date changes. The days stay on the dates they're already programmed for, so the week they fall in will change."
    }

    private var moveMessage: String {
        let direction = shiftInDays < 0 ? "earlier" : "later"
        let firstDay = edited.program?.keys.min()
            .map { $0.formatted(date: .abbreviated, time: .omitted) }
        let opening = "\(programmedDayCount) programmed days move \(abs(shiftInDays)) days \(direction)"
        guard let firstDay else { return opening + "." }
        return opening + ", starting \(firstDay). Prescriptions and logged workouts are untouched."
    }

    private var deleteMessage: String {
        guard programmedDayCount > 0 else {
            return "This block has nothing programmed in it."
        }
        return "\(programmedDayCount) programmed days go with it. Workouts already logged are kept."
    }

    /// Where today falls in the block as edited — "WEEK 6 / 12 · DAY 38", or an
    /// honest answer when the block hasn't started yet.
    private var todayDescription: String {
        guard let progress = edited.progress(asOf: Date(), calendar: calendar) else {
            return "unscheduled"
        }
        guard progress.dayIndex >= 1 else {
            let away = 1 - progress.dayIndex
            return away == 1 ? "starts tomorrow" : "starts in \(away) days"
        }
        let week = progress.totalWeeks.map { "week \(progress.weekIndex) / \($0)" }
            ?? "week \(progress.weekIndex)"
        return "\(week) · day \(progress.dayIndex)"
    }

    private var programRange: String? {
        let days = (edited.program ?? [:]).filter { !$0.value.isEmpty }.keys.sorted()
        guard let first = days.first, let last = days.last else { return nil }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }
}

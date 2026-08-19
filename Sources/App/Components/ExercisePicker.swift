import SwiftUI
import LiftingCoachModel
import LiftingCoachPersistence

/// The app's one exercise chooser, used by the tracker (adding or swapping a
/// lift mid-workout, filling an open-choice slot) and by the planner.
///
/// There were two of these — a themed one with filters in the tracker, and a
/// stripped, unthemed clone in the planner that had drifted a full redesign
/// behind. Same job, same catalog, so one control.
///
/// **Picking is a two-step, and that's deliberate.** A row used to commit on a
/// single tap, which meant choosing between ~870 near-identically named entries
/// with nothing on screen but the name — no equipment, no history, no way to
/// check you had the right one before it landed in your workout. Tapping now
/// opens `ExerciseDetailView`, which says what the exercise is and what you've
/// done with it, and commits on an explicit button.
struct ExercisePicker: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Pre-selects a muscle filter — the coach's target for an open-choice
    /// slot, or the muscle group of the lift being swapped out.
    var initialMuscleFilter: String?
    /// Pre-selects an equipment filter. Set when swapping a specific lift,
    /// where "another barbell movement" is the overwhelmingly likely intent.
    var initialEquipmentFilter: String?
    /// What the program suggested for this slot, if anything.
    var suggestions: [String] = []
    /// DEBUG only: pushes the detail screen for the first exercise matching
    /// this name, so `-openExercisePicker "Bench"` can screenshot a surface
    /// that's otherwise two taps deep. Nil in every real launch.
    var initialDetailQuery: String?
    let onPick: (Exercise) -> Void

    @State private var exercises: [Exercise] = []
    @State private var stats: [Int: ExerciseStats] = [:]
    @State private var query = ""
    @State private var muscleFilter: String?
    @State private var equipmentFilter: String?
    @State private var didApplyInitialFilters = false
    @State private var path: [Exercise] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                suggestionBar
                filterBar
                list
            }
            .screenGround()
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
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .navigationDestination(for: Exercise.self) { exercise in
                ExerciseDetailView(exercise: exercise) { picked in
                    onPick(picked)
                    dismiss()
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        exercises = (try? environment.exercises.fetchAll()) ?? []
        if let userID = environment.currentUser?.id {
            stats = (try? environment.exerciseStats.stats(for: userID)) ?? [:]
        }
        // Once, not on every re-entry: a lifter who cleared the muscle filter
        // to go looking further afield shouldn't have it snap back.
        guard !didApplyInitialFilters else { return }
        didApplyInitialFilters = true
        muscleFilter = initialMuscleFilter
        equipmentFilter = initialEquipmentFilter

        #if DEBUG
        if let initialDetailQuery,
           let match = exercises.first(where: {
               $0.name.localizedCaseInsensitiveContains(initialDetailQuery)
           }) {
            path = [match]
        }
        #endif
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty, !exercises.isEmpty {
            emptyState
        } else {
            List(filtered, id: \.self) { exercise in
                NavigationLink(value: exercise) {
                    ExercisePickerRow(exercise: exercise, stats: stats[exercise.id])
                }
                .listRowBackground(Theme.void)
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// Nothing matched — said out loud, with the way out on screen.
    ///
    /// This was a blank white list. Mid-workout that reads as a broken app, not
    /// as a search with no hits, and it left the lifter with nothing to tap:
    /// the search field held a term they hadn't typed (a suggestion chip put it
    /// there) and the filters were set by the slot. Core Tenets §10 — an empty
    /// state has to say what it is.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(Theme.inkFaint)
            Text("NO MATCHES")
                .font(Theme.label)
                .tracking(1.6)
                .foregroundStyle(Theme.inkMuted)
            Text(emptyDescription)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !query.isEmpty || muscleFilter != nil || equipmentFilter != nil {
                Button {
                    query = ""
                    muscleFilter = nil
                    equipmentFilter = nil
                } label: {
                    Text("SHOW EVERYTHING")
                        .font(Theme.label)
                        .tracking(1.4)
                        .foregroundStyle(Theme.signal)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Theme.signal.opacity(0.6), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .frame(maxWidth: .infinity)
        .screenGround()
    }

    /// Names what actually narrowed the list, so the lifter knows which control
    /// to reach for rather than guessing.
    private var emptyDescription: String {
        var applied: [String] = []
        if !query.isEmpty { applied.append("“\(query)”") }
        if let muscleFilter { applied.append(muscleFilter.lowercased()) }
        if let equipmentFilter { applied.append(equipmentFilter.lowercased()) }
        guard !applied.isEmpty else { return "The catalog is empty." }
        return "Nothing in the catalog matches " + applied.joined(separator: " + ") + "."
    }

    /// What the program floated for this slot — "overhead extension,"
    /// "pushdown." Tapping one searches for it.
    ///
    /// Suggestions, not a whitelist. The program leaving the movement open is
    /// the whole point of the slot, so these can't narrow what's pickable — the
    /// app doesn't overrule the lifter (Core Tenets §1). They stay *search*
    /// shortcuts rather than becoming filter chips for the same reason: a
    /// suggestion is the program's prose, not a catalog field, so a filter
    /// built from one would quietly behave like the whitelist it isn't.
    @ViewBuilder
    private var suggestionBar: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "programmed as")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button { apply(suggestion) } label: {
                                Text(suggestion)
                                    .font(Theme.data(13))
                                    .foregroundStyle(Theme.signal)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Theme.panelRaised)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    /// Tapping a suggestion searches for it — and drops the prefilters, which
    /// is the whole fix.
    ///
    /// The two used to stack, and stacked they contradict each other: the row
    /// slot prefilters to Middle Back, "Cable Row" matches *Seated Cable Rows*,
    /// and that lift's primary muscle is filed under a different group — so
    /// searching the coach's own suggestion returned nothing. The suggestion is
    /// the more specific instruction of the two, so it wins. The prefilters are
    /// visible chips and go back on in a tap.
    private func apply(_ suggestion: String) {
        query = suggestion
        muscleFilter = nil
        equipmentFilter = nil
    }

    /// Muscle and equipment chips, pre-set from the slot being filled.
    ///
    /// A prefilter is only acceptable because it's *visible* and clears in one
    /// tap — an active chip the lifter can see and switch off. A hidden filter
    /// would be the app quietly deciding what they're allowed to pick.
    ///
    /// Lift-family grouping (Larsen/Spoto/close-grip as bench variations) still
    /// isn't here; that needs a real notion of family on the catalog, not a
    /// name-substring guess.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if muscleFilter != nil || equipmentFilter != nil {
                    Button {
                        muscleFilter = nil
                        equipmentFilter = nil
                    } label: {
                        Label("Clear", systemImage: "xmark")
                            .font(Theme.data(13))
                            .foregroundStyle(Theme.inkMuted)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Theme.panelRaised)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Divider().frame(height: 18)
                }
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
                .font(Theme.data(13))
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

    /// Filtered, then **ordered by how much the lifter actually uses each
    /// lift**, most-performed first.
    ///
    /// Alphabetical order over ~870 catalog entries buries the twenty a person
    /// trains under 850 they will never pick. Usage order applies inside a
    /// search too: among the eleven entries matching "bench", the one done 200
    /// times is the likely answer.
    ///
    /// Name breaks the tie, so the list is stable and everything unperformed
    /// stays alphabetical rather than arbitrary.
    private var filtered: [Exercise] {
        exercises
            .filter { exercise in
                if let muscleFilter, exercise.muscleGroup != muscleFilter { return false }
                if let equipmentFilter, exercise.equipment != equipmentFilter { return false }
                if !query.isEmpty, !exercise.name.localizedCaseInsensitiveContains(query) { return false }
                return true
            }
            .sorted { a, b in
                let ca = stats[a.id]?.sessionCount ?? 0
                let cb = stats[b.id]?.sessionCount ?? 0
                if ca != cb { return ca > cb }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
    }
}

// MARK: - Row

private struct ExercisePickerRow: View {
    let exercise: Exercise
    let stats: ExerciseStats?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(exercise.muscleGroup.capitalized)
                    if let equipment = exercise.equipment {
                        Text("· \(equipment.capitalized)")
                    }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            // Only where there's something to say. A "0×" on 850 exercises is
            // noise that makes the twenty real ones harder to spot, and an
            // honest empty state is nothing at all (Core Tenets §10).
            if let stats, stats.sessionCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(stats.sessionCount)×")
                        .font(Theme.data(14, weight: .medium))
                        .foregroundStyle(Theme.signal)
                    if let last = stats.lastPerformed {
                        Text(last.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                            .font(Theme.label)
                            .foregroundStyle(Theme.inkFaint)
                            .lineLimit(1)
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

/// What an exercise is, and what this lifter has done with it.
///
/// The confirmation step of the picker, and the only screen that shows the
/// catalog's `instructions` — imported since the catalog landed and displayed
/// nowhere until now.
struct ExerciseDetailView: View {
    @Environment(AppEnvironment.self) private var environment

    let exercise: Exercise
    let onSelect: (Exercise) -> Void

    @State private var stats: ExerciseStats?
    @State private var sessions: [ExerciseSessionRecord] = []

    private var unit: WeightUnit { environment.weightUnit(forExerciseID: exercise.id) }

    var body: some View {
        List {
            tagSection
            historySection
            if let instructions = exercise.instructions, !instructions.isEmpty {
                instructionSection(instructions)
            }
        }
        .listStyle(.plain)
        .screenGround()
        .navigationTitle(exercise.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // A footer rather than a list row: the button that commits shouldn't be
        // something you have to scroll a long instruction list to reach.
        .safeAreaInset(edge: .bottom) { selectButton }
        .task {
            if let userID = environment.currentUser?.id {
                stats = (try? environment.exerciseStats.stats(for: userID))?[exercise.id]
            }
            sessions = (try? environment.exerciseStats.sessions(forExerciseID: exercise.id)) ?? []
        }
    }

    private var selectButton: some View {
        Button { onSelect(exercise) } label: {
            Text("Use This Exercise")
                .font(Theme.heading)
                .foregroundStyle(Theme.void)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.signal)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var tagSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                FlowRow(spacing: 6) {
                    Chip(text: exercise.muscleGroup.lowercased(), color: Theme.signal)
                    ForEach(tags, id: \.self) { tag in
                        Chip(text: tag.lowercased(), color: Theme.inkMuted)
                    }
                }
                if exercise.isOpenChoice {
                    Text("An open slot — the program names a goal here, not a movement. Nothing recorded under it counts toward a max.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
        }
        .panelRow()
    }

    private var tags: [String] {
        [exercise.equipment, exercise.category, exercise.mechanic, exercise.force, exercise.level]
            .compactMap { $0 }
    }

    @ViewBuilder
    private var historySection: some View {
        SectionLabel(text: "your history", accent: Theme.signal).panelRow()

        if let stats, stats.sessionCount > 0 {
            Panel {
                VStack(alignment: .leading, spacing: 9) {
                    Readout(label: "sessions", value: "\(stats.sessionCount)")
                    Readout(label: "sets logged", value: "\(stats.setCount)")
                    if let last = stats.lastPerformed {
                        Readout(
                            label: "last done",
                            value: last.formatted(.dateTime.month(.abbreviated).day().year())
                        )
                    }
                    if let heaviest = stats.heaviestWorkingSet {
                        Readout(
                            label: "heaviest working set",
                            value: heaviest.liftedDescription(in: unit)
                        )
                    }
                }
            }
            .panelRow()

            ForEach(sessions) { session in
                sessionRow(session)
            }
        } else {
            // Says the true thing rather than showing zeroes (Core Tenets §10).
            Panel {
                Text("Never logged.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            .panelRow()
        }
    }

    private func sessionRow(_ session: ExerciseSessionRecord) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(session.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(Theme.data(14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    if let variant = session.variant, !variant.isEmpty {
                        Text(variant)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkFaint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                ForEach(session.sets) { set in
                    Text(describe(set))
                        .font(Theme.data(13))
                        .foregroundStyle(set.type == .working ? Theme.ink : Theme.inkFaint)
                }
            }
        }
        .panelRow()
    }

    /// One logged set as a line: `5 × 225 lb @ 8`, or `12:00 · 2.4 mi` for work
    /// measured in time. Anything absent is left out rather than shown as zero.
    ///
    /// The reps-and-weight half is `SetSummaryLine.describe`, shared with the
    /// workout detail screen so the two can't render the same set differently.
    private func describe(_ set: WorkoutSet) -> String {
        var parts = [SetSummaryLine.describe(set, in: set.unit ?? unit)]
        if let rpe = set.rpe { parts.append("@ \(rpe.rpeDescription)") }
        if let type = set.type, type != .working { parts.append(type.rawValue.uppercased()) }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private func instructionSection(_ instructions: [String]) -> some View {
        SectionLabel(text: "how to").panelRow()
        Panel {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(instructions.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(index + 1)")
                            .font(Theme.label)
                            .foregroundStyle(Theme.inkFaint)
                            .frame(width: 14, alignment: .trailing)
                        Text(step)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .panelRow()
    }
}

// MARK: - Flow layout

/// Wraps its children onto as many lines as they need.
///
/// An `HStack` of chips overflows on a narrow phone and lets iOS truncate the
/// chips themselves, which reads as corrupted data rather than a tight layout —
/// the same failure the tracker's set row was fixed for.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

import SwiftUI
import LiftingCoachModel

/// The heart of the app — real-time set logging during a workout.
///
/// `Roadmap.md` names this as the first thing to build in phase 1: it's
/// fundamentally device-local and needs nothing from the backend.
struct WorkoutTrackerView: View {
    /// A day Home asked to start. Consumed once and cleared — see
    /// `consumePendingStart`.
    @Binding var pendingStart: PlannedWorkout?

    @Environment(AppEnvironment.self) private var environment
    @State private var model: TrackerModel?
    @State private var isPickingExercise = false
    @State private var isConfirmingFinish = false
    @State private var isConfirmingDiscard = false
    /// The current calendar week's plan — a lifter should be able to see (and
    /// start, or skip) more than just today.
    @State private var weekPlan: [PlannedWorkout] = []
    #if DEBUG
    /// Latches `-openExercisePicker` to a single presentation.
    @State private var didOpenDebugPicker = false
    #endif

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
            if model == nil, let userID = environment.currentUser?.id {
                let model = TrackerModel(
                    workouts: environment.workouts,
                    users: environment.users,
                    stats: environment.exerciseStats,
                    userID: userID,
                    notifier: RestNotifier(isEnabled: !isRestDemo),
                    onAchievedMaxRecorded: { environment.reloadUser() }
                )
                model.resumeIfNeeded()
                self.model = model
                #if DEBUG
                startRestDemoIfRequested(model)
                #endif
            }
            loadWeek()
            consumePendingStart()
            #if DEBUG
            // One-shot. `.task` re-runs every time this tab is selected, so
            // without the latch the picker re-opened on every return from Home
            // — which looked exactly like a bug in the Home card.
            //
            // A beat before presenting, too: setting this in the same turn as
            // the view's first appearance lands before there's anything to
            // present from, and the sheet silently never opens.
            if LaunchArguments.exercisePickerQuery != nil, !didOpenDebugPicker {
                didOpenDebugPicker = true
                try? await Task.sleep(for: .milliseconds(700))
                isPickingExercise = true
            }
            #endif
        }
        // Home may hand over a day while this tab is already built, in which
        // case `.task` has long since run.
        .onChange(of: pendingStart?.id) { _, _ in consumePendingStart() }
        .sheet(isPresented: $isPickingExercise) {
            ExercisePicker(initialDetailQuery: pickerDetailQuery) { exercise in
                model?.addExercise(exercise, sets: 1)
            }
        }
    }

    /// Under `-openExercisePicker`, the name to push a detail screen onto.
    /// Empty string means "open the list and stop there".
    private var pickerDetailQuery: String? {
        #if DEBUG
        let query = LaunchArguments.exercisePickerQuery
        return (query?.isEmpty ?? true) ? nil : query
        #else
        return nil
        #endif
    }

    /// True only under `-restDemo`, which is DEBUG-gated everywhere it acts.
    private var isRestDemo: Bool {
        #if DEBUG
        LaunchArguments.restDemoSeconds != nil
        #else
        false
        #endif
    }

    #if DEBUG
    /// Puts a running rest timer on screen for `-restDemo <seconds>`.
    ///
    /// Goes through the real path — log a set, which starts rest — rather than
    /// faking the state, so what gets screenshotted is what a lifter would see.
    /// The length is then forced to the requested value, since the timer's own
    /// target comes from the prescription and an ad-hoc set has none.
    private func startRestDemoIfRequested(_ model: TrackerModel) {
        guard let seconds = LaunchArguments.restDemoSeconds, !model.isActive else { return }
        let catalog = (try? environment.exercises.fetchAll()) ?? []
        guard let first = catalog.first else { return }

        model.startAdHoc()
        model.addExercise(first, sets: 2)
        // A second lift so the first one can be *finished* — completing an
        // exercise's last set hands "active" to the next, which is the state
        // that used to fold the finished exercise shut with a live countdown
        // still inside it. Reproducing that here is the only way to see it
        // without a UI test target.
        if catalog.count > 1 {
            model.addExercise(catalog[1], sets: 3)
        }

        let sets = model.session?.exerciseGroups.first?.first?.sets ?? []
        for set in sets {
            model.updateSet(id: set.id) { $0.reps = 5; $0.weight = Measurement(value: 225, unit: .pounds) }
            model.completeSet(id: set.id)
        }

        guard let last = sets.last,
              let started = model.session?.exercise(containingSetID: last.id)
        else { return }
        model.startRest(for: started, afterSetWith: last.id, seconds: seconds)
    }
    #endif

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

    /// Takes the day Home handed over, if there is one, and starts it.
    ///
    /// Cleared unconditionally, so a request is acted on at most once — coming
    /// back to this tab later must not restart the same day.
    ///
    /// **An in-progress workout wins.** If the lifter is already mid-session,
    /// the request is dropped rather than replacing it: starting from a plan
    /// would throw away sets that are already logged, and a tap on a home
    /// screen is nowhere near enough authority for that (Core Tenets §8). They
    /// land on the session they're actually in, which is what they wanted.
    private func consumePendingStart() {
        guard let planned = pendingStart else { return }
        pendingStart = nil
        guard let model, !model.isActive else { return }
        start(planned)
    }

    // MARK: Active workout

    private func activeWorkout(_ model: TrackerModel) -> some View {
        ActiveWorkoutList(
            model: model,
            unitFor: { environment.weightUnit(forExerciseID: $0) },
            onSetExerciseUnit: { environment.setExerciseUnit($1, forExerciseID: $0) },
            onAddExercise: { isPickingExercise = true }
        )
        .themedConfirm(
            isPresented: $isConfirmingFinish,
            title: "Finish this workout?",
            message: finishWarning(for: model),
            confirmLabel: "Finish",
            cancelLabel: "Keep Going",
            onConfirm: { model.finish() }
        )
        // Discard throws away every set logged so far and there is no undo, so
        // it asks first — the same courtesy finishing already got, for the
        // action that actually destroys something.
        .themedConfirm(
            isPresented: $isConfirmingDiscard,
            title: "Discard this workout?",
            message: discardWarning(for: model),
            confirmLabel: "Discard",
            cancelLabel: "Keep Going",
            onConfirm: { model.discard() }
        )
    }

    /// Say what's about to be dropped rather than letting it be discovered later.
    private func finishWarning(for model: TrackerModel) -> String {
        let progress = model.session?.progress ?? (completed: 0, total: 0)
        let skipped = progress.total - progress.completed
        guard skipped > 0 else { return "All sets are logged." }
        return "\(skipped) unfinished set\(skipped == 1 ? "" : "s") won't be saved."
    }

    /// Count what's about to be thrown away. "Nothing is logged yet" is worth
    /// saying too — it's the difference between a misfire and a real loss.
    private func discardWarning(for model: TrackerModel) -> String {
        let logged = model.session?.progress.completed ?? 0
        guard logged > 0 else { return "Nothing is logged yet." }
        return "\(logged) logged set\(logged == 1 ? "" : "s") will be deleted. This can't be undone."
    }

    /// A workout with nothing logged has nothing to finish; discarding is what
    /// that one wants.
    private func canFinish(_ model: TrackerModel) -> Bool {
        (model.session?.progress.completed ?? 0) > 0
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
                    .font(Theme.data(14, weight: .medium))
                    .foregroundStyle(progress.completed == progress.total ? Theme.signal : Theme.inkMuted)
            }
            // The two ways a workout ends, and nothing else. There was an
            // EditButton here driving \.editMode for drag-to-reorder; reorder
            // still works by long-pressing a row, and a mode toggle isn't worth
            // a permanent seat next to the only two decisions that matter.
            ToolbarItem(placement: .primaryAction) {
                Button("FINISH") { isConfirmingFinish = true }
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(canFinish(model) ? Theme.signal : Theme.inkFaint)
                    .disabled(!canFinish(model))
            }
            ToolbarItem(placement: .primaryAction) {
                Button("DISCARD", role: .destructive) { isConfirmingDiscard = true }
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
    /// The unit the lifter reads a given lift in — `exerciseUnits[id]`, then the
    /// app default. Passed as a function rather than a value because it now
    /// varies per exercise, and passed down rather than read from the
    /// environment here for the same reason `model` is: this list is
    /// deliberately a plain view over its inputs.
    let unitFor: (Int) -> WeightUnit
    /// Pins a lift to a unit, or clears it with `nil`. Sticky across sessions.
    let onSetExerciseUnit: (Int, WeightUnit?) -> Void
    let onAddExercise: () -> Void

    /// Per-exercise expand override. Absent means "default to expanded only if
    /// this is the active exercise" — a manual tap can push either direction.
    @State private var expandedOverrides: [UUID: Bool] = [:]
    @State private var noteEditorTarget: NoteEditorTarget?
    /// The exercise whose slot is being filled — an open-choice slot being
    /// resolved, or any exercise being swapped mid-workout.
    @State private var choosingFor: ChoosingTarget?

    /// Whether the list is in reorder mode: every exercise collapsed to a
    /// single draggable row.
    ///
    /// This exists because `.onMove` was quietly broken, and the fix had to be
    /// structural. `List` maps a drag onto the *element* of a `ForEach`, which
    /// only works when each element renders exactly one row — and an expanded
    /// exercise renders a header, a warmup button, every set, a rest line under
    /// each, and an add-set button. The drag looked right and landed nowhere,
    /// which is the same class of bug as the planner's "tapping the title adds
    /// a set": one `ForEach` element, many rows.
    ///
    /// Collapsing to one row per group is therefore not decoration — it is what
    /// makes the reorder work at all. It also happens to be the only legible way
    /// to do it: dragging a lift past three expanded exercises means dragging it
    /// past two screens of sets, with no way to see where it will land.
    @State private var isReordering = false
    @State private var didOpenLaunchReorder = false

    /// Which number is being typed, across the whole screen.
    ///
    /// Owned here rather than per field because NEXT has to *move* focus, and a
    /// field holding its own private `@FocusState` has no way to hand it on.
    /// See `SuggestingNumberField.focus`.
    @FocusState private var focusedField: SetField?

    /// The one set whose rest editor is open, if any.
    ///
    /// Owned here rather than inside `RestControl` because the editor is a
    /// *row* — placing it as a sibling of the set row is what keeps any single
    /// row from changing height, which is what made the clock and the steppers
    /// cross each other on the way in. One at a time, too: two open editors on
    /// one screen is the sort of clutter this control keeps being pruned of.
    @State private var expandedRest: UUID?

    var body: some View {
        List {
            if isReordering {
                reorderBanner
                reorderSections
            } else {
                statusSection
                groupSections
                actionSection
            }
        }
        .listStyle(.plain)
        .screenGround()
        // Drag handles, and a list that means to be dragged. Reorder mode is a
        // mode rather than a gesture you have to discover, which is also what
        // lets it collapse everything for the duration.
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        .animation(.easeOut(duration: 0.2), value: isReordering)
        .onAppear {
            // `-reorderMode`, latched: `.onAppear` runs again on every return
            // to this tab, and a mode that re-enters itself reads as a bug.
            guard !didOpenLaunchReorder, LaunchArguments.opensReorderMode else { return }
            didOpenLaunchReorder = true
            isReordering = true
        }
        // A safe-area inset rather than an overlay: the list runs *under* the
        // tab bar, so a bottom-aligned overlay puts the banner behind it. This
        // sits above the bar and lifts the list instead of covering its last row.
        .safeAreaInset(edge: .bottom, spacing: 0) { achievedMaxBanner }
        .animation(.easeOut(duration: 0.22), value: model.newAchievedMax?.max.date)
        // The lifter who *is* watching the screen still deserves to be told,
        // and a phone on the bench is felt before it's read. The notification
        // covers the case where the app isn't on screen at all.
        .onChange(of: model.rest?.hasExpired) { _, expired in
            guard expired == true else { return }
            // Sound and haptic, and *not* a panel. Expiry used to open the rest
            // editor so there'd be a DONE to press — which turned the end of
            // every rest period into a two-tap chore for a fact the lifter
            // already knew, and put a panel on screen they hadn't asked for.
            // The line says REST COMPLETE and one tap on it clears; checking
            // off the next set clears it too, which is what actually happens
            // next.
            RestChime.play()
        }
        // Rest moved to a different set — or ended. An editor left open on the
        // set it used to belong to is the "rest timer modifier is frequently
        // open, I don't think I'm trying to open it" report: it was opened by
        // the *previous* set's expiry and then stranded there when the timer
        // moved on.
        .onChange(of: model.rest?.setID) { previous, _ in
            guard let previous, expandedRest == previous else { return }
            expandedRest = nil
        }
        .sheet(item: $noteEditorTarget) { target in
            NoteSheet(
                title: "Note",
                context: programmedNote(for: target).map { ("programmed", $0) },
                note: usernoteBinding(for: target)
            )
        }
        .sheet(item: $choosingFor) { target in
            ExercisePicker(
                initialMuscleFilter: target.muscleGroup,
                initialEquipmentFilter: target.equipment,
                suggestions: target.suggestions
            ) { picked in
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
    }

    /// A PR announces itself at the foot of the screen, not at the top of the
    /// list.
    ///
    /// It used to be the first row — which is the one place it was guaranteed
    /// not to be seen, since the set that earned it is somewhere further down
    /// and that's where the lifter is looking. As an overlay it's on screen
    /// wherever the list is scrolled to, and it stays until acknowledged: a max
    /// is worth a deliberate tap, and a banner that vanishes on a timer while
    /// someone is racking a bar is a banner they'll wonder if they imagined.
    @ViewBuilder
    private var achievedMaxBanner: some View {
        if let record = model.newAchievedMax {
            AchievedMaxBanner(
                exercise: record.exercise,
                max: record.max,
                unit: unitFor(record.exercise.id)
            ) {
                model.dismissAchievedMaxBanner()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Reorder mode

    /// The way out, and the only thing on screen that isn't a lift.
    private var reorderBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.signal)
            Text("DRAG TO REORDER")
                .font(Theme.label)
                .tracking(1.4)
                .foregroundStyle(Theme.inkMuted)
            Spacer(minLength: 8)
            Button("DONE") { isReordering = false }
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(Theme.signal)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .panelRow()
        // Nothing to drag here, and letting the banner be dragged would put a
        // non-exercise into the exercise ordering.
        .moveDisabled(true)
    }

    /// One row per group, which is what makes `.onMove` land.
    ///
    /// A superset is one row carrying both names — the pair moves together,
    /// matching `moveGroup`'s granularity, and splitting it across two rows
    /// would reintroduce the many-rows-per-element bug this mode exists to fix.
    @ViewBuilder
    private var reorderSections: some View {
        let groups = model.session?.exerciseGroups ?? []
        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
            ReorderRow(
                group: group,
                position: groupIndex + 1,
                isActive: model.session?.activeExercise?.group == groupIndex
            )
            .panelRow()
        }
        .onMove { offsets, destination in
            guard let source = offsets.first else { return }
            model.moveGroup(from: source, to: destination)
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
                exerciseRows(
                    exercise: exercise,
                    groupIndex: groupIndex,
                    isSuperset: group.count > 1
                )
            }
        }
        // No `.onMove` here on purpose. It was here, and it was broken: each
        // element of this `ForEach` renders many rows, so `List` had nothing
        // stable to map a drag onto and the exercise sprang back. Reordering
        // lives in `reorderSections`, where one element is one row.
    }

    @ViewBuilder
    private func exerciseRows(
        exercise: WorkoutExercise,
        groupIndex: Int,
        isSuperset: Bool
    ) -> some View {
        let isActiveGroup = model.session?.activeExercise?.group == groupIndex
        let sets = exercise.sets ?? []
        let restTimer = model.rest?.exerciseID == exercise.id ? model.rest : nil
        // Defaults to expanded for the exercise being worked, and for one whose
        // rest is still running: completing an exercise's last set hands
        // "active" to the next lift, which used to fold this one shut with a
        // live countdown inside it. A tap still overrides in either direction.
        let expanded = expandedOverrides[exercise.id] ?? (isActiveGroup || restTimer != nil)
        // A superset's members share an accent so they read as one unit. A
        // caption above two otherwise-identical exercises doesn't say they're
        // paired — it says there's a caption. Live still wins: whichever lift
        // is being worked is the more urgent fact.
        let accent: Color = if isActiveGroup {
            Theme.live.opacity(0.55)
        } else if isSuperset {
            Theme.signal.opacity(0.45)
        } else {
            Theme.hairline
        }
        // The middle level of the unit chain. A set may still override it.
        let exerciseUnit = unitFor(exercise.exercise.id)

        ExerciseHeaderRow(
            exercise: exercise,
            isActive: isActiveGroup,
            isExpanded: expanded,
            unit: exerciseUnit,
            isSupersetted: (model.session?.exerciseGroups[groupIndex].count ?? 1) > 1,
            supersetCandidates: supersetCandidates(excluding: exercise.id),
            onToggleExpanded: { expandedOverrides[exercise.id] = !expanded },
            onReorder: {
                // Rest editors are rows of their own, so one left open would
                // put a second row under a set and break the set-level move
                // the same way the exercise-level one was broken.
                expandedRest = nil
                isReordering = true
            },
            onSetUnit: { onSetExerciseUnit(exercise.exercise.id, $0) },
            onSuperset: { model.superset(id: exercise.id, with: $0) },
            onUngroup: { model.ungroup(id: exercise.id) },
            onAddDropSet: { model.addDropSet(toExerciseWith: exercise.id) },
            onDelete: { model.deleteExercise(id: exercise.id) },
            onEditNote: { noteEditorTarget = .exercise(exercise.id) },
            onChooseExercise: {
                let open = exercise.exercise.isOpenChoice
                choosingFor = ChoosingTarget(
                    id: exercise.id,
                    // An open slot filters to the muscle group the coach named.
                    // A *swap* filters to what's being replaced — someone
                    // changing barbell rows is looking for another back
                    // movement, and usually another barbell one. Both are
                    // visible chips that clear in a tap.
                    muscleGroup: exercise.exercise.muscleGroup,
                    equipment: open ? nil : exercise.exercise.equipment,
                    suggestions: open ? (exercise.exercise.suggestions ?? []) : []
                )
            }
        )
        .panelGroupRow(expanded ? .top : .single, accent: accent)

        if expanded {
            // Ramp-up sets belong above the prescription, not appended after
            // it: a program says what to work up *to*, and how you get there is
            // the lifter's call on the day. Named for what it makes, because
            // the type is load-bearing — a warmup never records an achieved max.
            Button { model.addWarmupSet(toExerciseWith: exercise.id) } label: {
                Label("Add Warmup Set", systemImage: "plus")
                    .font(Theme.data(13, weight: .medium))
                    .foregroundStyle(Theme.inkFaint)
            }
            .buttonStyle(.plain)
            .panelGroupRow(.middle, accent: accent)

            ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                // The countdown lives *inside* this row rather than as a row of
                // its own, so it stays welded to the set that started it —
                // through a reorder, and with the set's own swipe-to-delete
                // still targeting the set.
                let restingHere = restTimer.map { $0.setID == set.id } ?? false

                VStack(spacing: 0) {
                    SetRow(
                        // Counted among its own kind, so two warmups don't
                        // rename the first working set to "03".
                        number: ordinal(of: set, at: index, in: sets),
                        set: set,
                        suggestion: model.suggestion(forSetAt: index, in: exercise),
                        focus: $focusedField,
                        // Weight → reps → the next set's weight. The chain is
                        // built here because a row can't see the row below it.
                        nextSetID: index + 1 < sets.count ? sets[index + 1].id : nil,
                        isNextUp: model.session?.nextSet?.id == set.id,
                        // Most specific wins: this set's own unit, else the
                        // exercise's, else the app default.
                        unit: set.unit ?? exerciseUnit,
                        exerciseUnit: exerciseUnit,
                        hasUnitOverride: set.unit != nil,
                        onToggle: {
                            toggle(set, suggestion: model.suggestion(forSetAt: index, in: exercise))
                        },
                        onRepsChange: { reps in model.updateSet(id: set.id) { $0.reps = reps } },
                        onWeightChange: { weight in model.updateSet(id: set.id) { $0.weight = weight } },
                        onRPEChange: { rpe in model.updateSet(id: set.id) { $0.rpe = rpe } },
                        onUnitChange: { unit in model.updateSet(id: set.id) { $0.unit = unit } },
                        onTypeChange: { type in model.updateSet(id: set.id) { $0.type = type } },
                        onEditNote: { noteEditorTarget = .set(set.id) },
                        onDelete: { model.deleteSet(id: set.id) }
                    )

                    // Every set carries its rest, on the line under it, in the
                    // one control the app has for rest. When this set's rest is
                    // the one running, that same line *is* the countdown.
                    restLine(for: set, timer: restingHere ? restTimer : nil)
                        .padding(.top, 8)
                }
                .panelGroupRow(.middle, accent: restingHere ? Theme.live : accent)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        model.deleteSet(id: set.id)
                    }
                    // The app's accent is cyan, and a swipe action inherits it
                    // — which drew "Delete" in the same colour as every safe,
                    // affirmative control in the app. Destructive reads red.
                    .tint(Theme.alert)
                }

                // The editor is a row of its own, under the set's. Nothing
                // already on screen changes size when it appears, which is the
                // whole reason it lives out here instead of inside the line.
                if expandedRest == set.id {
                    restEditor(for: set, timer: restingHere ? restTimer : nil)
                        .panelGroupRow(.middle, accent: restingHere ? Theme.live : accent)
                }
            }
            // One element, one row — which is what makes this move land, and
            // exactly what the exercise-level move couldn't promise. An open
            // rest editor adds a second row for one set, so dragging is off
            // rather than broken while one is on screen.
            .onMove { offsets, destination in
                guard let source = offsets.first else { return }
                model.moveSet(from: source, to: destination, within: exercise.id)
            }
            // Applied after `onMove`, which is what keeps the `ForEach` a
            // `DynamicViewContent` long enough to take it.
            .moveDisabled(expandedRest != nil)

            // The set that started this rest is gone — deleted mid-countdown.
            // The rest is still real, so it falls back to the foot of the
            // exercise rather than vanishing along with the row.
            if let restTimer, !sets.contains(where: { $0.id == restTimer.setID }) {
                runningRestLine(restTimer)
                    .panelGroupRow(.middle, accent: Theme.live)
                if expandedRest == restTimer.setID {
                    runningRestEditor(restTimer)
                        .panelGroupRow(.middle, accent: Theme.live)
                }
            }

            Button { model.addSet(toExerciseWith: exercise.id) } label: {
                Label("Add Set", systemImage: "plus")
                    .font(Theme.data(13, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(.plain)
            .panelGroupRow(.bottom, accent: accent)
        }
    }

    /// Where this set sits among the sets of its own type — the same rule
    /// `SetSuggestion` matches on, so the number on screen and the number the
    /// suggestion was drawn from agree.
    private func ordinal(of set: WorkoutSet, at index: Int, in sets: [WorkoutSet]) -> Int {
        let type = set.type ?? .working
        return sets[..<index].filter { ($0.type ?? .working) == type }.count + 1
    }

    /// A set's rest — the prescription, or the countdown when it's this set's
    /// rest that's running. One control either way; see `RestControl`.
    @ViewBuilder
    private func restLine(for set: WorkoutSet, timer: RestTimer?) -> some View {
        RestControl(
            mode: mode(for: set, timer: timer),
            isExpanded: expandedRest == set.id,
            onToggleExpanded: { expandedRest = expandedRest == set.id ? nil : set.id },
            onPrimaryTap: timer?.hasExpired == true ? { model.dismissRest() } : nil,
            // A typed duration is this set's rest, or — while it's counting —
            // what's left on the clock.
            onSet: { seconds in
                if timer == nil {
                    model.setRest(seconds, forSetWith: set.id)
                } else {
                    model.setRestRemaining(seconds)
                }
            }
        )
    }

    private func runningRestLine(_ timer: RestTimer) -> some View {
        RestControl(
            mode: .running(timer),
            isExpanded: expandedRest == timer.setID,
            onToggleExpanded: {
                expandedRest = expandedRest == timer.setID ? nil : timer.setID
            },
            // A finished rest needs acknowledging, not editing. One tap on the
            // line clears it; the caret still opens the editor for the lifter
            // who wants to put time back on the clock.
            onPrimaryTap: timer.hasExpired ? { model.dismissRest() } : nil,
            onSet: { model.setRestRemaining($0) }
        )
    }

    @ViewBuilder
    private func restEditor(for set: WorkoutSet, timer: RestTimer?) -> some View {
        if let timer {
            runningRestEditor(timer)
        } else {
            let prescribed = model.session?.prescribedRest(afterSetWith: set.id) ?? 120
            let isTuned = set.restOverride != nil
            RestEditor(
                mode: mode(for: set, timer: nil),
                onSet: { model.setRest($0, forSetWith: set.id) },
                // Only offered once there's something to go back to.
                actionLabel: isTuned ? "reset \(prescribed.restClockDescription)" : nil,
                onAction: isTuned ? { model.setRest(nil, forSetWith: set.id) } : nil
            )
        }
    }

    private func runningRestEditor(_ timer: RestTimer) -> some View {
        RestEditor(
            mode: .running(timer),
            onAdjust: { model.adjustRest(by: $0) },
            onSet: { model.setRestRemaining($0) },
            actionLabel: timer.hasExpired ? "done" : "skip",
            onAction: {
                model.dismissRest()
                expandedRest = nil
            }
        )
    }

    /// A set's rest is its own countdown when one is running, and its
    /// prescription otherwise — the line and the editor must agree on which.
    private func mode(for set: WorkoutSet, timer: RestTimer?) -> RestControl.Mode {
        if let timer { return .running(timer) }
        return .prescription(
            seconds: model.session?.restTarget(afterSetWith: set.id) ?? 120,
            isExplicit: set.restOverride != nil
        )
    }

    /// Adding an exercise is the only action that belongs at the foot of the
    /// list. Finishing moved to the toolbar — a second "Finish Workout" button
    /// down here was a second way to do the one thing.
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
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .panelRow()
    }

    /// The exercises this one could be paired with — everything else in the
    /// workout, named as the lifter sees them. Pairing is only offered against
    /// something that exists, so a one-exercise workout gets no menu entry.
    private func supersetCandidates(excluding id: UUID) -> [(id: UUID, name: String)] {
        (model.session?.exerciseGroups ?? [])
            .flatMap { $0 }
            .filter { $0.id != id }
            .map { (id: $0.id, name: $0.displayName) }
    }

    /// Checking off an untouched set commits whatever was proposed in it.
    ///
    /// That's the convention Strong and Hevy set and it's the frictionless path
    /// `Features/Workout Tracker.md` asks for — but it's only honest because
    /// the number was on screen, in a field, before the tap. The lifter has
    /// seen it and can type over it; the checkbox is the confirmation.
    ///
    /// `completeSet` already takes reps/weight overrides, so nothing in the
    /// model has to know suggestions exist.
    private func toggle(_ set: WorkoutSet, suggestion: SetSuggestion.Values? = nil) {
        if set.complete == true {
            model.uncompleteSet(id: set.id)
        } else {
            model.completeSet(
                id: set.id,
                reps: set.reps == nil ? suggestion?.reps : nil,
                weight: set.weight == nil ? suggestion?.weight : nil
            )
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
    /// The muscle group to pre-filter by: the coach's target for an open slot,
    /// or the outgoing exercise's own when swapping.
    let muscleGroup: String?
    /// Set when swapping a specific lift rather than filling an open slot —
    /// "another barbell movement" is the overwhelmingly likely intent.
    var equipment: String?
    /// Movements the program floated for this slot. Shortcuts into the search,
    /// never a restriction on it — the lifter picks what they pick.
    var suggestions: [String] = []
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
                            .font(.system(size: 13, weight: .semibold))
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
        (workout.exercises ?? []).flatMap { $0 }.map(\.displayName)
    }
}

// MARK: - Exercise header

private struct ExerciseHeaderRow: View {
    let exercise: WorkoutExercise
    let isActive: Bool
    let isExpanded: Bool
    /// The unit this lift resolves to today, for the checkmark in the menu.
    let unit: WeightUnit
    /// Whether this exercise is currently sharing a group with another.
    let isSupersetted: Bool
    /// Everything else in the workout, as pairing targets.
    let supersetCandidates: [(id: UUID, name: String)]
    let onToggleExpanded: () -> Void
    /// Enters reorder mode — see `ActiveWorkoutList.isReordering`.
    let onReorder: () -> Void
    /// Pins this lift to a unit for good, or clears it back to the app default.
    let onSetUnit: (WeightUnit?) -> Void
    let onSuperset: (UUID) -> Void
    let onUngroup: () -> Void
    let onAddDropSet: () -> Void
    let onDelete: () -> Void
    let onEditNote: () -> Void
    let onChooseExercise: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpanded) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(exercise.displayName)
                            .font(Theme.heading)
                            .foregroundStyle(Theme.ink)
                            // Two lines rather than one: program exercise names are
                            // long and descriptive ("Deadlift — heavy (straight
                            // bar)"), and a single line truncates the part that
                            // distinguishes it from the other three deadlift days.
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        // The catalog lift underneath the plan's wording —
                        // which is what a logged max is recorded against, so
                        // it shouldn't be invisible while lifting.
                        if exercise.variant != nil {
                            Text(exercise.exercise.name)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.inkFaint)
                                .lineLimit(1)
                        }
                    }
                    if isActive {
                        Chip(text: "active", color: Theme.live)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // The coach specified a goal, not a movement — and this is the
            // control that resolves it, not a caption about it.
            //
            // It used to be a plain `Chip` *inside* the expand button, so the
            // one thing on the row that names an unmade decision did nothing
            // when tapped except fold the exercise shut. Choosing was only
            // reachable through the `…` menu, which is where it was reported
            // from the gym floor as "the selector did not open on interaction".
            // The obvious affordance is now the real one; the menu entry stays
            // for the swap case.
            if exercise.exercise.isOpenChoice {
                Button(action: onChooseExercise) {
                    HStack(spacing: 4) {
                        Text("YOUR CHOICE")
                            .font(Theme.label)
                            .tracking(1.2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.signal)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Theme.signal.opacity(0.6), lineWidth: 1)
                    )
                    .fixedSize()
                    .contentShape(.rect)
                }
                // A `List` row runs its own tap through every plain button in
                // it unless each says otherwise; without this, tapping the chip
                // also toggled the expansion behind it.
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            if !isExpanded {
                Text(collapsedProgress)
                    .font(Theme.data(14))
                    .foregroundStyle(Theme.inkMuted)
            }

            if let notes = exercise.usernotes, !notes.isEmpty {
                Image(systemName: "note.text")
                    .font(.system(size: 13))
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
                // Sticky, and the menu says so — a control that silently
                // changes every future session is worse than one that doesn't.
                // Pairing is a decision made at the rack, not something that
                // can only arrive from a plan.
                if isSupersetted {
                    Button("Remove From Superset", systemImage: "arrow.up.and.down.and.arrow.left.and.right", action: onUngroup)
                } else if !supersetCandidates.isEmpty {
                    Menu("Superset With", systemImage: "arrow.triangle.merge") {
                        ForEach(supersetCandidates, id: \.id) { candidate in
                            Button(candidate.name) { onSuperset(candidate.id) }
                        }
                    }
                }
                Button("Add Drop Set", systemImage: "arrow.down.right", action: onAddDropSet)
                Button("Reorder Exercises", systemImage: "arrow.up.arrow.down", action: onReorder)
                Menu("Unit — \(unit.symbol)", systemImage: "scalemass") {
                    Picker("Unit", selection: unitSelection) {
                        ForEach(WeightUnit.allCases, id: \.self) { option in
                            Text(option == .pounds ? "Pounds (lb)" : "Kilograms (kg)")
                                .tag(Optional(option))
                        }
                    }
                    Button("Use App Default") { onSetUnit(nil) }
                }
                Button("Edit Note", systemImage: "note.text", action: onEditNote)
                Button("Delete Exercise", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    /// Writes through on pick; reading it back is what puts the checkmark on
    /// the unit currently in force, inherited or not.
    private var unitSelection: Binding<WeightUnit?> {
        Binding(get: { unit }, set: { onSetUnit($0) })
    }

    private var collapsedProgress: String {
        let sets = exercise.sets ?? []
        guard !sets.isEmpty else { return "0 SETS" }
        let done = sets.filter { $0.complete == true }.count
        return "\(done)/\(sets.count)"
    }
}

// MARK: - Set row

/// One typeable number, addressed so focus can move between them.
///
/// This is what makes NEXT possible: a `@FocusState` has to hold a value the
/// whole screen agrees on, and `Bool` per field can only ever say "me" or "not
/// me". Weight and reps are separate cases rather than one case with a flag so
/// the chain reads as what it is — `.weight(a) → .reps(a) → .weight(b)`.
enum SetField: Hashable {
    case weight(UUID)
    case reps(UUID)
}

/// One exercise group, collapsed to a single draggable row.
///
/// Everything a lifter needs to place it and nothing else: where it sits, what
/// it is, and how much of it is done. A superset shows both names, because the
/// pair moves as one.
private struct ReorderRow: View {
    let group: [WorkoutExercise]
    let position: Int
    let isActive: Bool

    var body: some View {
        Panel(accent: isActive ? Theme.live.opacity(0.55) : Theme.hairline) {
            HStack(spacing: 10) {
                Text("\(position)")
                    .font(Theme.data(14, weight: .medium))
                    .foregroundStyle(Theme.inkFaint)
                    .frame(minWidth: 16, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group) { exercise in
                        Text(exercise.displayName)
                            .font(Theme.heading)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if group.count > 1 {
                    Chip(text: "superset", color: Theme.signal)
                }
                if isActive {
                    Chip(text: "live", color: Theme.live)
                }
                Text(progress)
                    .font(Theme.data(14))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize()
            }
        }
    }

    /// Completed over total across the whole group — a paired lift's progress
    /// is the pair's.
    private var progress: String {
        let sets = group.flatMap { $0.sets ?? [] }
        let done = sets.filter { $0.complete == true }.count
        return "\(done)/\(sets.count)"
    }
}

private struct SetRow: View {
    /// This set's position **among sets of its own kind** — warmup 1, 2, 3 and
    /// working 1, 2, 3, each counting from one.
    ///
    /// Numbering used to run straight down the exercise, which meant adding two
    /// warmups renamed the first working set to "03". The number a lifter wants
    /// while working is which set of the prescription they're on, and warmups
    /// aren't part of it.
    let number: Int
    let set: WorkoutSet
    /// What the lifter did last time, shown greyed in whichever of reps/weight
    /// is still empty. A proposal, never a prescription — see `SetSuggestion`.
    let suggestion: SetSuggestion.Values?
    /// The screen's focus, so this row's NEXT can reach the row below it.
    let focus: FocusState<SetField?>.Binding
    /// The set after this one, or nil at the end of the exercise.
    let nextSetID: UUID?
    let isNextUp: Bool
    /// The unit this row reads and writes weights in — already resolved by the
    /// caller through `set.unit ?? exerciseUnit ?? preferredUnit`.
    let unit: WeightUnit
    /// What this set would fall back to, for the menu's "use exercise default".
    let exerciseUnit: WeightUnit
    /// Whether this set is overriding that fallback, for the menu's checkmark.
    let hasUnitOverride: Bool
    let onToggle: () -> Void
    let onRepsChange: (Int?) -> Void
    let onWeightChange: (Measurement<UnitMass>?) -> Void
    let onRPEChange: (Float?) -> Void
    let onUnitChange: (WeightUnit?) -> Void
    /// Retypes a set after the fact — warmup / working / drop. Load-bearing:
    /// `AchievedMaxUpdate` only ever records a max from a `.working` set.
    let onTypeChange: (SetType) -> Void
    let onEditNote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            quantities
            if hasAnnotations {
                annotations
            }
        }
        .padding(.vertical, 2)
    }

    private var hasAnnotations: Bool {
        prescription != nil || showsSuggestionTag
    }

    /// Whether a greyed number is currently standing in for an entry.
    ///
    /// Drives the `LAST` tag, which exists because contrast alone can't say
    /// "this is a proposal": the placeholder meets AA as text (it's committable
    /// by tapping the checkbox, so it has to), which necessarily brings it
    /// closer to an entered value. WCAG §1.4.1 — never colour as the only
    /// channel — and it answers the more useful question anyway, which is
    /// *where the number came from*.
    private var showsSuggestionTag: Bool {
        guard !done, let suggestion else { return false }
        return !suggestion.isEmpty
    }

    /// A completed set keeps `Theme.ink` rather than dimming to `inkMuted`.
    /// Reps and weight are lift data — you read set 1's weight while doing set
    /// 3 — and AAA (7:1) applies to them; `inkMuted` is 5.47:1. Done-ness is
    /// carried by font weight instead, which is the better channel anyway:
    /// state should never be colour alone (WCAG §1.4.1).
    ///
    /// Every quantity is visible and directly tappable — no expand step. Reps
    /// and weight are inline text fields; RPE is a chip opening `RPEPicker`,
    /// constrained to the app's 1–10 by 0.5 scale (Core Tenets §3) so an
    /// out-of-range or RIR-scaled value can't be entered. Rest is the same kind
    /// of control, on the line below for room.
    ///
    /// Width-agnostic by construction: nothing here has a fixed width, and the
    /// two fields share the free space proportionally. An earlier version
    /// pinned each field to a point width, which at 375pt (SE) overflowed and
    /// let iOS truncate the *labels* instead — the set number rendered as "…"
    /// and the unit "lb" as "l", which reads as corrupted data rather than a
    /// tight layout.
    private var quantities: some View {
        HStack(spacing: 6) {
            checkboxButton

            typeBadge

            SuggestingNumberField(
                value: weightBinding,
                // Read in this row's unit like everything else, so a suggestion
                // drawn from a set logged in kg still reads in pounds here.
                suggestion: suggestion?.weight?.expressed(in: unit).value,
                label: "weight",
                isActive: !done,
                font: Theme.data(15, weight: done ? .regular : .medium),
                foreground: Theme.ink,
                // One plate per side, in the unit the plates are marked in.
                step: unit == .pounds ? 2.5 : 1,
                onStep: { delta in
                    let current = self.set.weight?.expressed(in: unit).value ?? 0
                    onWeightChange(Measurement(value: max(0, current + delta), unit: weightUnit))
                },
                focus: focus,
                id: .weight(self.set.id),
                next: .reps(self.set.id)
            )
            .layoutPriority(2)

            Text(weightUnit.symbol)
                .font(Theme.data(13))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            Text("×")
                .font(Theme.data(14))
                .foregroundStyle(Theme.inkFaint)
                .fixedSize()

            SuggestingNumberField(
                value: repsBinding,
                suggestion: suggestion?.reps.map(Double.init),
                fractionDigits: 0,
                label: "reps",
                isActive: !done,
                font: Theme.data(15, weight: done ? .regular : .medium),
                foreground: Theme.ink,
                step: 1,
                onStep: { delta in onRepsChange(max(0, (self.set.reps ?? 0) + Int(delta))) },
                focus: focus,
                id: .reps(self.set.id),
                next: nextSetID.map { .weight($0) }
            )
            .layoutPriority(1)

            RPEPicker(
                value: self.set.rpe,
                clearLabel: "not rated",
                onChange: onRPEChange
            )

            setMenu
        }
    }

    /// The set's index, and its kind, in one tappable badge: `W1`, `2`, `D1`.
    ///
    /// This is the row's answer to "no way to toggle or see which sets are
    /// warmup or working". Seeing it was previously a small uppercase word on
    /// the *second* line, and only for non-working sets; changing it meant
    /// finding a `Picker` three levels inside the `…` menu. Both now live on
    /// the number that was already sitting there doing nothing.
    ///
    /// The letter is the channel, not the colour (WCAG §1.4.1) — the tint only
    /// reinforces it, which matters because the badge is small and the app is
    /// read at arm's length.
    private var typeBadge: some View {
        Menu {
            Picker("Set Type", selection: typeSelection) {
                ForEach(SetType.allCases, id: \.self) { type in
                    Text(type.rawValue.capitalized).tag(type)
                }
            }
        } label: {
            Text(badgeText)
                .font(Theme.data(13, weight: setType == .working ? .regular : .medium))
                .foregroundStyle(badgeInk)
                .frame(minWidth: 24)
                // Never let the index be the thing that gets truncated.
                .fixedSize()
                .padding(.vertical, 3)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var setType: SetType { self.set.type ?? .working }

    private var badgeText: String {
        switch setType {
        case .warmup: "W\(number)"
        case .working: String(format: "%02d", number)
        case .drop: "D\(number)"
        }
    }

    private var badgeInk: Color {
        switch setType {
        case .warmup: Theme.inkFaint
        case .working: Theme.inkMuted
        case .drop: Theme.signal.opacity(0.8)
        }
    }

    /// Unit, note, delete. Set type used to be in here too and has moved to the
    /// badge at the head of the row — a control buried three levels inside a
    /// `…` menu is one the lifter reported as not existing, and the row already
    /// had a place where the set's kind belongs.
    private var setMenu: some View {
        Menu {
            Menu("Unit — \(unit.symbol)", systemImage: "scalemass") {
                Picker("Unit", selection: unitSelection) {
                    ForEach(WeightUnit.allCases, id: \.self) { option in
                        Text(option == .pounds ? "Pounds (lb)" : "Kilograms (kg)")
                            .tag(Optional(option))
                    }
                }
                // Only offered when it would do something.
                if hasUnitOverride {
                    Button("Use Exercise Default (\(exerciseUnit.symbol))") { onUnitChange(nil) }
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

    private var unitSelection: Binding<WeightUnit?> {
        Binding(get: { unit }, set: { onUnitChange($0) })
    }

    private var typeSelection: Binding<SetType> {
        Binding(get: { self.set.type ?? .working }, set: { onTypeChange($0) })
    }

    /// The quiet second line: what was *prescribed*, where that isn't already
    /// the number in a field above.
    ///
    /// Rest used to live here as a chip. It has its own line under this row now
    /// — the same `RestControl` that becomes the countdown — because a chip
    /// here plus a countdown below plus the popover the chip opened made three
    /// ways to say one thing, two of them on screen at once.
    ///
    /// The prescription text wraps rather than truncating: this is the only
    /// place a percentage that didn't resolve to a weight is visible at all,
    /// and silently clipping it would violate Core Tenets §10.
    private var annotations: some View {
        HStack(alignment: .center, spacing: 10) {
            if let prescription {
                Text(prescription)
                    .font(Theme.data(12))
                    .foregroundStyle(done ? Theme.inkMuted : Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsSuggestionTag {
                Text("LAST")
                    .font(Theme.label)
                    .tracking(1.1)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize()
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 38)
    }

    private var checkboxButton: some View {
        // Logging the set is what a lifter reaches for after typing into it, so
        // it doubles as the way off the keyboard — and giving up focus is what
        // commits the number they just typed.
        Button { dismissKeyboard(); onToggle() } label: {
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
                        .font(.system(size: 13, weight: .bold))
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

    /// Optional on purpose. An unlogged set has *no* reps, and binding a
    /// non-optional rendered that as `0` — a number nobody performed, sitting
    /// in the field as though it were data.
    private var repsBinding: Binding<Double?> {
        Binding(
            get: { self.set.reps.map(Double.init) },
            set: { onRepsChange($0.map { Int($0.rounded()) }) }
        )
    }

    /// Reads and writes in the lifter's own unit.
    ///
    /// A set logged last month in pounds converts for display, and editing it
    /// writes back in kg — which is right: the number on screen is the number
    /// they're committing. `expressed(in:)` rounds to two decimals precisely so
    /// that tapping into a converted field and tapping out again can't drift
    /// the weight in a decimal place nobody can see.
    private var weightBinding: Binding<Double?> {
        Binding(
            get: { self.set.weight?.expressed(in: unit).value },
            set: { onWeightChange($0.map { Measurement(value: $0, unit: weightUnit) }) }
        )
    }

    /// The unit this row reads and writes in — the resolved end of the chain
    /// `set.unit ?? exerciseUnit ?? user.preferredUnit`, decided by the caller.
    ///
    /// It briefly meant "the lifter's app-wide unit, always." That was right
    /// when the app-wide preference was the only one that existed: a preference
    /// the tracker overrode whenever a program happened to be written in pounds
    /// would have been a preference in name only. Now there are two more
    /// specific preferences above it, both authored by the lifter — a lift
    /// pinned to kg, and one set done on the kg rack — and the most specific
    /// authored answer wins, exactly as rest resolves (Core Tenets §1).
    ///
    /// What has *not* changed: none of this touches storage. A set logged at
    /// 225 lb stays a 225 lb row; the chain decides what it's rendered as.
    private var weightUnit: UnitMass { unit.unit }

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

// MARK: - Achieved max banner

private struct AchievedMaxBanner: View {
    let exercise: Exercise
    let max: AchievedMax
    let unit: WeightUnit
    let onDismiss: () -> Void

    var body: some View {
        Panel(accent: Theme.live) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.live)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEW MAX")
                        .font(Theme.label)
                        .tracking(1.6)
                        .foregroundStyle(Theme.live)
                    Text("\(exercise.name.uppercased()) — \(max.weight.liftedDescription(in: unit))")
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

#Preview {
    WorkoutTrackerView(pendingStart: .constant(nil))
        .environment(AppEnvironment.preview())
}

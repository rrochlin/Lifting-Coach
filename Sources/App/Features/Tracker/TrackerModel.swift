import Foundation
import Observation
import LiftingCoachModel
import LiftingCoachPersistence

/// View state for the Workout Tracker.
///
/// Owns a `WorkoutSession` and persists after every mutation. Saving on each
/// change rather than on finish is deliberate: `WorkoutStore.fetchInProgress`
/// only helps if the rows are already on disk when the app dies, and the app
/// dying mid-workout is routine — the phone goes in a bag between sets.
@Observable
@MainActor
final class TrackerModel {
    private(set) var session: WorkoutSession?
    private(set) var saveError: String?

    /// The rest period in progress, if any. See `RestTimer`.
    private(set) var rest: RestTimer?

    /// The workout that just ended, held for the summary the lifter sees on
    /// the way out. Cleared by `dismissSummary()`.
    ///
    /// Kept here rather than in the view because `finish` is what knows the
    /// final shape of it — incomplete sets have been dropped by then, so a copy
    /// taken beforehand would report sets that aren't in the log.
    private(set) var justFinished: Workout?

    /// A just-recorded achieved max, for a transient banner. The lifter should
    /// know the PR was actually captured, not just quietly written to disk.
    private(set) var newAchievedMax: (exercise: Exercise, max: AchievedMax)?

    private let notifier: RestNotifier
    /// Wakes the model at expiry so the timer can announce itself (haptic,
    /// expired state) while the app is on screen. The scheduled notification
    /// covers the other case; this covers the lifter who *is* watching.
    private var restExpiryTask: Task<Void, Never>?
    /// Clears the finished timer a couple of seconds after it announces itself.
    private var restDismissTask: Task<Void, Never>?

    private let workouts: WorkoutStore
    private let users: UserStore
    private let stats: ExerciseStatsStore
    private let userID: UUID
    /// Called after an achieved max is recorded, so the view can refresh
    /// `AppEnvironment.currentUser` — TrackerModel doesn't hold a reference to
    /// the environment itself, to keep it independently testable.
    private let onAchievedMaxRecorded: () -> Void

    init(
        workouts: WorkoutStore,
        users: UserStore,
        stats: ExerciseStatsStore,
        userID: UUID,
        notifier: RestNotifier = RestNotifier(),
        onAchievedMaxRecorded: @escaping () -> Void = {}
    ) {
        self.workouts = workouts
        self.users = users
        self.stats = stats
        self.userID = userID
        self.notifier = notifier
        self.onAchievedMaxRecorded = onAchievedMaxRecorded
    }

    var isActive: Bool { session != nil }

    // MARK: Lifecycle

    /// Picks up an interrupted workout, if one is on disk.
    func resumeIfNeeded() {
        guard session == nil else { return }
        do {
            if let workout = try workouts.fetchInProgress() {
                session = WorkoutSession(workout: workout)
                loadSuggestionHistory()
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    func startAdHoc(at date: Date = Date()) {
        session = WorkoutSession.adHoc(at: date)
        loadSuggestionHistory()
        persist()
    }

    func start(from planned: PlannedWorkout, block: WorkoutBlock? = nil, user: User? = nil) {
        session = WorkoutSession.start(from: planned, block: block, user: user)
        loadSuggestionHistory()
        persist()
    }

    func finish(at date: Date = Date()) {
        guard var session else { return }
        session.finish(at: date)
        self.session = session
        dismissRest()
        persist()
        justFinished = session.workout
        self.session = nil
        // A workout only becomes history when it ends, so this is exactly when
        // the derived per-lift stats go stale. Recomputed rather than nudged —
        // `finish` has just dropped every incomplete set, which is precisely
        // the kind of thing an incremental counter gets wrong.
        try? stats.rebuild(for: userID)
    }

    /// Abandons the workout without saving it as history.
    func discard() {
        if let session {
            try? workouts.delete(id: session.workout.id)
        }
        session = nil
        dismissRest()
    }

    // MARK: Editing

    func completeSet(id: UUID, reps: Int? = nil, weight: Measurement<UnitMass>? = nil, rpe: Float? = nil, at date: Date = Date()) {
        mutate { $0.completeSet(id: id, reps: reps, weight: weight, rpe: rpe, at: date) }

        // Start the rest clock from the set that was just logged.
        if let session, let exercise = session.exercise(containingSetID: id) {
            startRest(
                for: exercise,
                afterSetWith: id,
                // What the lifter walks to when this rest is up. Read *after*
                // the set was completed, so it's the genuinely next unlogged
                // set rather than the one just finished.
                upNext: session.nextSet.flatMap {
                    session.exercise(containingSetID: $0.id)?.displayName
                },
                seconds: session.restTarget(afterSetWith: id),
                from: date
            )
        }

        recordAchievedMaxIfNeeded(setID: id, at: date)
    }

    /// Achieved maxes come from sets, not manual entry (Core Tenets §6) — a
    /// heavier weight than the current best *is* the new best, checked every
    /// time a set is completed.
    ///
    /// The max lands on the exercise itself, which is already the canonical
    /// lift: a program names the movement it means by slug, so heavy paused
    /// bench, its back-offs, and a Spoto press are all the one bench press
    /// entry, told apart by `variant`. They share a max because they *are* the
    /// same lift — nothing has to roll one up onto another.
    ///
    /// This used to resolve a separate "which canonical entry did a matcher
    /// think this variation was?" link before recording. That link is gone with
    /// the matcher, and it isn't missed: identity now comes from the program,
    /// not from a guess about the exercise's name.
    private func recordAchievedMaxIfNeeded(setID: UUID, at date: Date) {
        guard let session,
              let performed = session.exercise(containingSetID: setID)?.exercise,
              let set = session.workout.allSets.first(where: { $0.id == setID })
        else { return }

        do {
            let currentBest = try users.fetch(id: userID)?.latestAchievedMax(for: performed.id)
            guard let update = AchievedMaxUpdate.evaluate(
                set: set, for: performed, currentBest: currentBest, at: date
            ) else { return }

            try users.recordAchievedMax(update, exerciseId: performed.id, for: userID)
            newAchievedMax = (performed, update)
            onAchievedMaxRecorded()
        } catch {
            // A missed max update shouldn't interrupt logging the set itself —
            // the workout write already succeeded via `persist()`.
            saveError = error.localizedDescription
        }
    }

    // MARK: Suggestions

    /// Last completed session for each exercise in this workout, keyed by
    /// `Exercise.id` — where the greyed proposals in empty set fields come
    /// from.
    ///
    /// Loaded once when the session starts rather than per row: the picker is
    /// not on screen, the log isn't changing underneath us, and a query per set
    /// per redraw would be an aggregate in the hot path of a workout.
    private(set) var lastSessions: [Int: [WorkoutSet]] = [:]

    private func loadSuggestionHistory() {
        guard let session else { return }
        var loaded: [Int: [WorkoutSet]] = [:]
        for exercise in session.exerciseGroups.flatMap({ $0 }) {
            let id = exercise.exercise.id
            guard loaded[id] == nil else { continue }
            // Open-choice slots are deliberately included: unlike an achieved
            // max, "what did I load last time I did some triceps thing" is a
            // useful starting point even when it might not be the same
            // movement — because it's a proposal the lifter edits, not a
            // record being compared (Core Tenets §6 vs §1).
            if let previous = try? stats.lastSession(forExerciseID: id) {
                loaded[id] = previous.sets
            }
        }
        lastSessions = loaded
    }

    /// What to propose for one set, or nil if there's nothing to say.
    ///
    /// **No history is not the same as nothing to say**, and this used to treat
    /// it as if it were: a `guard let` on `lastSessions` returned nil before
    /// `SetSuggestion` was ever asked, which killed its "the set above speaks"
    /// fallback in precisely the case it exists for. A lift with no logged
    /// history — a new exercise, a fresh install, the first session on this
    /// phone — is where typing 90 into the first set and finding the four below
    /// it still blank was reported from ("fill in lower working sets with
    /// weight I enter above"). An empty array is the honest input; the rule for
    /// what to do with it lives in one place, and it is not here.
    func suggestion(forSetAt index: Int, in exercise: WorkoutExercise) -> SetSuggestion.Values? {
        SetSuggestion.forSet(
            at: index,
            in: exercise.sets ?? [],
            previous: lastSessions[exercise.exercise.id] ?? []
        )
    }

    func dismissAchievedMaxBanner() {
        newAchievedMax = nil
    }

    func dismissSummary() {
        justFinished = nil
    }

    func uncompleteSet(id: UUID) {
        mutate { $0.uncompleteSet(id: id) }
    }

    func updateSet(id: UUID, _ change: (inout WorkoutSet) -> Void) {
        mutate { $0.updateSet(id: id, change) }
    }

    /// Tunes (or clears, with `nil`) one set's rest.
    ///
    /// Deliberately does **not** touch a rest period already counting down: the
    /// timer is this rest, the set's value is the next one. Retuning what's on
    /// the clock is what the timer's own ±30 buttons are for.
    func setRest(_ seconds: Int?, forSetWith id: UUID) {
        mutate { $0.setRest(seconds, forSetWith: id) }
    }

    func updateExercise(id: UUID, _ change: (inout WorkoutExercise) -> Void) {
        mutate { $0.updateExercise(id: id, change) }
        // Filling an open-choice slot changes which lift this is, and therefore
        // whose history to propose from.
        loadSuggestionHistory()
    }

    func addSet(toExerciseWith id: UUID) {
        mutate { $0.addSet(toExerciseWith: id) }
    }

    /// Ramp-up sets, in front of what the program prescribed.
    func addWarmupSet(toExerciseWith id: UUID) {
        mutate { $0.addWarmupSet(toExerciseWith: id) }
    }

    func deleteSet(id: UUID) {
        mutate { $0.deleteSet(id: id) }
    }

    func addExercise(_ exercise: Exercise, sets: Int = 1) {
        mutate { $0.addExercise(exercise, sets: sets) }
        // An exercise chosen mid-workout has its own history, and it's exactly
        // the case suggestions matter most for — an unplanned lift arrives with
        // no prescription at all.
        loadSuggestionHistory()
    }

    func deleteExercise(id: UUID) {
        mutate { $0.deleteExercise(id: id) }
    }

    /// Ramp-down sets, after what the program prescribed.
    func addDropSet(toExerciseWith id: UUID) {
        mutate { $0.addDropSet(toExerciseWith: id) }
    }

    /// Pairs two exercises into a superset, mid-workout.
    func superset(id: UUID, with other: UUID) {
        mutate { $0.superset(id: id, with: other) }
    }

    /// Pulls an exercise back out of its superset.
    func ungroup(id: UUID) {
        mutate { $0.ungroup(id: id) }
    }

    func moveGroup(from source: Int, to destination: Int) {
        mutate { $0.moveGroup(from: source, to: destination) }
    }

    func moveSet(from source: Int, to destination: Int, within exerciseID: UUID) {
        mutate { $0.moveSet(from: source, to: destination, within: exerciseID) }
    }

    // MARK: Rest

    /// Begins (or restarts) the rest period following a logged set.
    func startRest(
        for exercise: WorkoutExercise,
        afterSetWith setID: UUID,
        upNext: String? = nil,
        seconds: Int,
        from date: Date = Date()
    ) {
        let timer = RestTimer(
            exerciseID: exercise.id,
            setID: setID,
            exerciseName: exercise.displayName,
            upNext: upNext,
            seconds: seconds,
            from: date
        )
        rest = timer
        Task { await notifier.requestAuthorizationIfNeeded() }
        scheduleExpiry(for: timer, now: date)
    }

    /// Extends or shortens the rest in progress — the ± buttons on the timer.
    /// The clamping rules live in `RestTimer.adjust(by:now:)`.
    func adjustRest(by seconds: Int, now: Date = Date()) {
        guard var timer = rest else { return }
        timer.adjust(by: seconds, now: now)
        rest = timer
        scheduleExpiry(for: timer, now: now)
    }

    /// Replaces what's left on the clock — the lifter tapping the countdown
    /// itself and picking a duration, rather than nudging it by ±30.
    func setRestRemaining(_ seconds: Int, now: Date = Date()) {
        guard var timer = rest else { return }
        timer.setRemaining(seconds, now: now)
        rest = timer
        scheduleExpiry(for: timer, now: now)
    }

    /// Ends rest early, or dismisses an expired timer.
    func dismissRest() {
        rest = nil
        restExpiryTask?.cancel()
        restExpiryTask = nil
        restDismissTask?.cancel()
        restDismissTask = nil
        notifier.cancel()
    }

    /// How long REST COMPLETE stays on screen before clearing itself.
    ///
    /// Long enough to be seen by someone who looked up at the sound, short
    /// enough that it isn't a thing to deal with. It was permanent until
    /// acknowledged, which made the end of every rest period a small chore for
    /// a fact the lifter already had — reported as "when a timer's completed it
    /// should dismiss or tap to dismiss, dismiss on next interaction". Tapping
    /// still clears it immediately, and so does checking off the next set.
    static let expiredLinger: Duration = .seconds(2)

    /// How late an expiry can fire and still count as happening *now*.
    ///
    /// The in-app path fires within milliseconds of `endsAt`; anything beyond
    /// this arrived because the app was suspended and has just come back. Three
    /// seconds is far outside the first case and far inside the second.
    private static let staleExpiry: TimeInterval = 3

    /// Arms both the on-screen expiry and the notification for a timer's end.
    private func scheduleExpiry(for timer: RestTimer, now: Date = Date()) {
        restExpiryTask?.cancel()
        // Putting time back on an expired clock cancels the tidy-up that was
        // about to clear it.
        restDismissTask?.cancel()
        restDismissTask = nil
        notifier.schedule(at: timer.endsAt, upNext: timer.upNext, now: now)

        let interval = timer.endsAt.timeIntervalSince(now)
        guard interval > 0 else {
            markRestExpired(timerID: timer.id)
            return
        }

        restExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.markRestExpired(timerID: timer.id)
        }
    }

    /// Guarded by `timerID` so a task that outlives its rest period — the lifter
    /// logged the next set early — can't expire whatever timer replaced it.
    ///
    /// **The chime fires from here rather than from the view**, which is the
    /// other half of "I had it open and the sound didn't fire": it hung off an
    /// `onChange` in the tracker's list, so a lifter who had switched to
    /// another tab — or whose list had been torn down for any other reason —
    /// got the notification and no sound. Expiry is a fact about the session,
    /// and the session is here.
    private func markRestExpired(timerID: UUID, now: Date = Date()) {
        guard var timer = rest, timer.id == timerID else { return }
        timer.hasExpired = true
        rest = timer

        // **A late expiry is a stale one, and it must not make a sound.**
        // `Task.sleep` doesn't run while the app is suspended, so a rest that
        // ended in the lifter's pocket fires the instant they reopen the app —
        // "if I'm not on the app I don't get the sound, but when I open the app
        // the sound plays". The notification already announced it at the right
        // moment; chiming now is announcing something that finished minutes
        // ago. Checking elapsed time rather than the app's state is what makes
        // this work, because on reopen the app *is* active.
        guard now.timeIntervalSince(timer.endsAt) < Self.staleExpiry else {
            dismissRest()
            return
        }
        RestChime.play()

        restDismissTask?.cancel()
        restDismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.expiredLinger)
            guard !Task.isCancelled else { return }
            // Re-checked rather than assumed: the lifter may have put more time
            // on the clock in the meantime, and clearing *that* timer would
            // throw away a rest period they had just asked for.
            guard let self, self.rest?.id == timerID, self.rest?.hasExpired == true else { return }
            self.dismissRest()
        }
    }

    // MARK: Plumbing

    private func mutate(_ change: (inout WorkoutSession) -> Void) {
        guard var session else { return }
        change(&session)
        self.session = session
        persist()
    }

    private func persist() {
        guard let session else { return }
        do {
            try workouts.save(session.workout)
            saveError = nil
        } catch {
            // Surfaced rather than swallowed: a workout that looks logged but
            // isn't on disk is worse than one that reports a problem.
            saveError = error.localizedDescription
        }
    }
}

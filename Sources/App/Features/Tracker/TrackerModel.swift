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

    /// A just-recorded achieved max, for a transient banner. The lifter should
    /// know the PR was actually captured, not just quietly written to disk.
    private(set) var newAchievedMax: (exercise: Exercise, max: AchievedMax)?

    private let notifier: RestNotifier
    /// Wakes the model at expiry so the timer can announce itself (haptic,
    /// expired state) while the app is on screen. The scheduled notification
    /// covers the other case; this covers the lifter who *is* watching.
    private var restExpiryTask: Task<Void, Never>?

    private let workouts: WorkoutStore
    private let users: UserStore
    private let userID: UUID
    /// Called after an achieved max is recorded, so the view can refresh
    /// `AppEnvironment.currentUser` — TrackerModel doesn't hold a reference to
    /// the environment itself, to keep it independently testable.
    private let onAchievedMaxRecorded: () -> Void

    init(
        workouts: WorkoutStore,
        users: UserStore,
        userID: UUID,
        notifier: RestNotifier = RestNotifier(),
        onAchievedMaxRecorded: @escaping () -> Void = {}
    ) {
        self.workouts = workouts
        self.users = users
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
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    func startAdHoc(at date: Date = Date()) {
        session = WorkoutSession.adHoc(at: date)
        persist()
    }

    func start(from planned: PlannedWorkout, block: WorkoutBlock? = nil, user: User? = nil) {
        session = WorkoutSession.start(from: planned, block: block, user: user)
        persist()
    }

    func finish(at date: Date = Date()) {
        guard var session else { return }
        session.finish(at: date)
        self.session = session
        dismissRest()
        persist()
        self.session = nil
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

    func dismissAchievedMaxBanner() {
        newAchievedMax = nil
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
    }

    func addSet(toExerciseWith id: UUID) {
        mutate { $0.addSet(toExerciseWith: id) }
    }

    func deleteSet(id: UUID) {
        mutate { $0.deleteSet(id: id) }
    }

    func addExercise(_ exercise: Exercise, sets: Int = 1) {
        mutate { $0.addExercise(exercise, sets: sets) }
    }

    func deleteExercise(id: UUID) {
        mutate { $0.deleteExercise(id: id) }
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
        seconds: Int,
        from date: Date = Date()
    ) {
        let timer = RestTimer(
            exerciseID: exercise.id,
            setID: setID,
            exerciseName: exercise.displayName,
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

    /// Ends rest early, or dismisses an expired timer.
    func dismissRest() {
        rest = nil
        restExpiryTask?.cancel()
        restExpiryTask = nil
        notifier.cancel()
    }

    /// Arms both the on-screen expiry and the notification for a timer's end.
    private func scheduleExpiry(for timer: RestTimer, now: Date = Date()) {
        restExpiryTask?.cancel()
        notifier.schedule(at: timer.endsAt, exerciseName: timer.exerciseName, now: now)

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
    private func markRestExpired(timerID: UUID) {
        guard var timer = rest, timer.id == timerID else { return }
        timer.hasExpired = true
        rest = timer
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

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

    /// When the current rest period is due to end. `nil` when not resting.
    private(set) var restEndsAt: Date?

    private let workouts: WorkoutStore

    init(workouts: WorkoutStore) {
        self.workouts = workouts
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
        restEndsAt = nil
        persist()
        self.session = nil
    }

    /// Abandons the workout without saving it as history.
    func discard() {
        if let session {
            try? workouts.delete(id: session.workout.id)
        }
        session = nil
        restEndsAt = nil
    }

    // MARK: Editing

    func completeSet(id: UUID, reps: Int? = nil, weight: Measurement<UnitMass>? = nil, rpe: Float? = nil, at date: Date = Date()) {
        mutate { $0.completeSet(id: id, reps: reps, weight: weight, rpe: rpe, at: date) }

        // Start the rest clock from the set that was just logged.
        if let session, session.workout.allSets.contains(where: { $0.id == id }) {
            restEndsAt = date.addingTimeInterval(TimeInterval(session.restTarget(afterSetWith: id)))
        }
    }

    func uncompleteSet(id: UUID) {
        mutate { $0.uncompleteSet(id: id) }
    }

    func updateSet(id: UUID, _ change: (inout WorkoutSet) -> Void) {
        mutate { $0.updateSet(id: id, change) }
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

    func dismissRest() {
        restEndsAt = nil
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

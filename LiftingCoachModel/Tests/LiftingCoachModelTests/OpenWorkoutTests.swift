import Foundation
import Testing
@testable import LiftingCoachModel

private let squat = ExerciseCatalog.seed[0]
private let start = Date(timeIntervalSince1970: 1_770_000_000)
private func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

@Suite("A workout left open")
struct OpenWorkoutTests {

    private func session(sets: Int = 3) -> WorkoutSession {
        var session = WorkoutSession.adHoc(at: start)
        session.addExercise(squat, sets: sets)
        return session
    }

    @Test("With nothing logged, idleness is measured from the start")
    func idleFromStart() {
        let workout = session().workout
        #expect(OpenWorkout.lastActivity(of: workout) == start)
        #expect(!OpenWorkout.isIdle(workout, at: minutes(19)))
        #expect(OpenWorkout.isIdle(workout, at: minutes(20)))
    }

    @Test("Each completed set restarts the clock")
    func completedSetRestartsClock() {
        var session = self.session()
        let first = session.workout.allSets[0].id
        session.completeSet(id: first, reps: 5, weight: Measurement(value: 225, unit: .pounds), at: minutes(15))

        #expect(OpenWorkout.lastActivity(of: session.workout) == minutes(15))
        #expect(!OpenWorkout.isIdle(session.workout, at: minutes(30)))
        #expect(OpenWorkout.isIdle(session.workout, at: minutes(35)))
    }

    @Test("Answering 'still going' restarts the clock from the answer")
    func acknowledgementRestartsClock() {
        let workout = session().workout
        #expect(!OpenWorkout.isIdle(workout, at: minutes(30), acknowledgedAt: minutes(25)))
        #expect(OpenWorkout.isIdle(workout, at: minutes(45), acknowledgedAt: minutes(25)))
        // An answer older than the last activity changes nothing.
        #expect(OpenWorkout.idleDeadline(of: workout, acknowledgedAt: minutes(-5)) == minutes(20))
    }

    @Test("A finished workout is never idle")
    func finishedIsNeverIdle() {
        var session = self.session()
        session.finish(at: minutes(5))
        #expect(OpenWorkout.idleDeadline(of: session.workout) == nil)
        #expect(!OpenWorkout.isIdle(session.workout, at: minutes(500)))
    }

    @Test("Logged sets are what discarding would lose")
    func countsLoggedSets() {
        var session = self.session()
        #expect(OpenWorkout.loggedSetCount(of: session.workout) == 0)
        let first = session.workout.allSets[0].id
        session.completeSet(id: first, reps: 5, weight: Measurement(value: 225, unit: .pounds), at: minutes(3))
        #expect(OpenWorkout.loggedSetCount(of: session.workout) == 1)
    }
}

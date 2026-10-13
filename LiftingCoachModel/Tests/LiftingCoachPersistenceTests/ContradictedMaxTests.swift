import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

/// The repair for a max the tracker recorded from a weight that was never
/// lifted — see `UserStore.repairContradictedMaxes`.
@Suite("Contradicted maxes")
struct ContradictedMaxTests {
    private let bench = ExerciseCatalog.seed[1]
    private let when = Date(timeIntervalSince1970: 1_770_000_000)

    private func lb(_ value: Double) -> Measurement<UnitMass> { Measurement(value: value, unit: .pounds) }

    private struct Fixture {
        let users: UserStore
        let workouts: WorkoutStore
        let user: User
    }

    private func fixture() throws -> Fixture {
        let database = try AppDatabase.inMemory()
        try ExerciseStore(database).save(ExerciseCatalog.seed)
        let users = UserStore(database)
        return Fixture(users: users, workouts: WorkoutStore(database), user: try users.localUser())
    }

    /// One finished workout holding one set of bench, completed at `when`
    /// (or `minutes` after it).
    private func log(
        _ fixture: Fixture, weight: Measurement<UnitMass>?, type: SetType = .working, complete: Bool = true,
        minutes: Double = 0
    ) throws {
        let set = WorkoutSet(
            reps: 3, weight: weight, complete: complete, type: type,
            timeComplete: complete ? when.addingTimeInterval(minutes * 60) : nil
        )
        var workout = Workout(startTime: when.addingTimeInterval(-600))
        workout.endTime = when.addingTimeInterval(600)
        workout.exercises = [[WorkoutExercise(exercise: bench, sets: [set])]]
        try fixture.workouts.save(workout)
    }

    private func maxes(_ fixture: Fixture) throws -> [Double] {
        (try fixture.users.fetch(id: fixture.user.id)?.achievedMaxes?[bench.id] ?? []).map(\.weight.value)
    }

    private func record(_ fixture: Fixture, _ weight: Measurement<UnitMass>, at date: Date? = nil) throws {
        try fixture.users.recordAchievedMax(
            AchievedMax(weight: weight, date: date ?? when), exerciseId: bench.id, for: fixture.user.id
        )
    }

    /// The reported bug, exactly: programmed 285, lowered to 245, checkbox
    /// tapped — and 285 recorded as a max at that set's timestamp.
    @Test("A max the set that earned it doesn't carry is retracted")
    func retracts() throws {
        let fixture = try self.fixture()
        try log(fixture, weight: lb(245))
        try record(fixture, lb(285))

        #expect(try fixture.users.repairContradictedMaxes(for: fixture.user.id) == 1)
        // 285 was never lifted. 245 was, and with nothing before it, it is
        // honestly the best on record.
        #expect(try maxes(fixture) == [245])
    }

    /// From the owner's real log: Face Pull had 100 lb recorded against a set
    /// that was 50, and the set that truly reached 100 six minutes later
    /// recorded nothing because 100 was "already" the best. Retracting alone
    /// would have left the lift with no max.
    @Test("The true maxes a false one suppressed are re-derived from the log")
    func rederives() throws {
        let fixture = try self.fixture()
        try log(fixture, weight: lb(50))
        try log(fixture, weight: lb(100), minutes: 6)
        try log(fixture, weight: lb(100), minutes: 11)
        try record(fixture, lb(100))

        #expect(try fixture.users.repairContradictedMaxes(for: fixture.user.id) == 1)
        // 50 was the best when it was lifted; 100 became it six minutes on;
        // the second 100 equalled it and is not a new max.
        #expect(try maxes(fixture) == [50, 100])
        let dates = try fixture.users.fetch(id: fixture.user.id)?.achievedMaxes?[bench.id]?.map(\.date)
        #expect(dates == [when, when.addingTimeInterval(360)])
    }

    @Test("A max from before the bad one still stands, and still has to be beaten")
    func earlierMaxStands() throws {
        let fixture = try self.fixture()
        try record(fixture, lb(275), at: when.addingTimeInterval(-86_400))
        try log(fixture, weight: lb(245))
        try record(fixture, lb(285))

        try fixture.users.repairContradictedMaxes(for: fixture.user.id)
        #expect(try maxes(fixture) == [275])
    }

    @Test("A max its set does carry is kept — in either unit")
    func keepsSupported() throws {
        let fixture = try self.fixture()
        // 285 lb, stored in kilograms.
        try log(fixture, weight: Measurement(value: 129.2738, unit: .kilograms))
        try record(fixture, lb(285))

        #expect(try fixture.users.repairContradictedMaxes(for: fixture.user.id) == 0)
        #expect(try maxes(fixture) == [285])
    }

    @Test("A set since un-checked, or retyped as a warmup, no longer supports its max")
    func uncompletedOrRetyped() throws {
        let unchecked = try self.fixture()
        try log(unchecked, weight: lb(285), complete: false)
        // An un-checked set has no completion time, so nothing sits at the
        // max's timestamp to contradict it — it is left alone, not guessed at.
        try record(unchecked, lb(285))
        #expect(try unchecked.users.repairContradictedMaxes(for: unchecked.user.id) == 0)

        let retyped = try self.fixture()
        try log(retyped, weight: lb(285), type: .warmup)
        try record(retyped, lb(285))
        #expect(try retyped.users.repairContradictedMaxes(for: retyped.user.id) == 1)
        // A warmup isn't an attempt at a limit, so nothing replaces it.
        #expect(try maxes(retyped).isEmpty)
    }

    @Test("A max with no set at its timestamp is left alone")
    func leavesUnmatched() throws {
        let fixture = try self.fixture()
        try log(fixture, weight: lb(245))
        // Recorded some other way, at some other time: nothing contradicts it.
        try record(fixture, lb(300), at: when.addingTimeInterval(86_400))

        #expect(try fixture.users.repairContradictedMaxes(for: fixture.user.id) == 0)
        #expect(try maxes(fixture) == [300])
    }

    @Test("Running it twice changes nothing the second time")
    func idempotent() throws {
        let fixture = try self.fixture()
        try log(fixture, weight: lb(245))
        try record(fixture, lb(285))
        try record(fixture, lb(300), at: when.addingTimeInterval(86_400))

        try fixture.users.repairContradictedMaxes(for: fixture.user.id)
        let once = try maxes(fixture)
        #expect(try fixture.users.repairContradictedMaxes(for: fixture.user.id) == 0)
        #expect(try maxes(fixture) == once)
    }
}

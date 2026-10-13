import Testing
@testable import LiftingCoachModel

@Suite("How an exercise is logged")
struct ExerciseTrackingTests {
    private func exercise(_ id: Int, category: String?) -> Exercise {
        var exercise = ExerciseCatalog.seed[0]
        exercise.id = id
        exercise.category = category
        return exercise
    }

    @Test("The catalog's cardio entries are timed; everything else is weight and reps")
    func defaults() {
        #expect(exercise(1, category: "cardio").defaultTracking == .timed)
        #expect(exercise(1, category: "Cardio").defaultTracking == .timed)
        #expect(exercise(1, category: "strength").defaultTracking == .strength)
        // An imported or program-created exercise carries no category.
        #expect(exercise(1, category: nil).defaultTracking == .strength)
    }

    @Test("The lifter's own choice wins over the catalog, per exercise")
    func override() {
        let plank = exercise(7, category: "strength")
        let run = exercise(8, category: "cardio")
        let user = User(name: "A", email: "", exerciseTracking: [7: .timed])

        #expect(user.tracking(for: plank) == .timed)
        #expect(user.tracking(for: run) == .timed)
        #expect(User(name: "A", email: "", exerciseTracking: [8: .strength]).tracking(for: run) == .strength)
    }

    @Test("Digits fill from the right, like a stopwatch")
    func durationDigits() {
        #expect(DurationEntry.seconds(fromDigits: "45") == 45)
        #expect(DurationEntry.seconds(fromDigits: "230") == 150)
        #expect(DurationEntry.seconds(fromDigits: "3000") == 1800)
        #expect(DurationEntry.seconds(fromDigits: "13000") == 5400)
        // Read as typed rather than rejected.
        #expect(DurationEntry.seconds(fromDigits: "90") == 90)
        #expect(DurationEntry.seconds(fromDigits: "") == nil)
        #expect(DurationEntry.seconds(fromDigits: "0") == 0)
    }

    @Test("A duration reads as m:ss, growing an hours place only when it needs one")
    func durationFormat() {
        #expect(DurationEntry.format(seconds: 45) == "0:45")
        #expect(DurationEntry.format(seconds: 1800) == "30:00")
        #expect(DurationEntry.format(seconds: 5400) == "1:30:00")
    }

    @Test("A stored duration goes back into the field as the digits that made it")
    func durationRoundTrip() {
        for seconds in [45, 150, 1800, 5400, 3599] {
            let digits = DurationEntry.digits(forSeconds: seconds)
            #expect(DurationEntry.seconds(fromDigits: digits) == seconds)
        }
        #expect(DurationEntry.digits(forSeconds: 1800) == "3000")
    }

    /// What the keyboard bar shows as digits go in. `90` must read `0:90`,
    /// not `1:30` — it's on its way to `9:00`.
    @Test("Digits in progress are shown by position, nothing carried")
    func positionalEntry() {
        #expect(DurationEntry.positional(digits: "9") == "0:09")
        #expect(DurationEntry.positional(digits: "90") == "0:90")
        #expect(DurationEntry.positional(digits: "900") == "9:00")
        #expect(DurationEntry.positional(digits: "3000") == "30:00")
        #expect(DurationEntry.positional(digits: "13000") == "1:30:00")
        #expect(DurationEntry.positional(digits: "0") == "0:00")
        #expect(DurationEntry.positional(digits: "") == "")
    }

    @Test("Each prefix of what's typed is already a valid time")
    func everyKeystrokeReads() {
        var typed = ""
        var seen: [Int] = []
        for key in "3000" {
            typed.append(key)
            seen.append(DurationEntry.seconds(fromDigits: typed) ?? -1)
        }
        #expect(seen == [3, 30, 180, 1800])
    }

    @Test("The unit setting reads as miles or kilometres on a timed exercise")
    func distanceUnits() {
        #expect(WeightUnit.pounds.distanceUnit == .miles)
        #expect(WeightUnit.kilograms.distanceUnit == .kilometers)
    }
}

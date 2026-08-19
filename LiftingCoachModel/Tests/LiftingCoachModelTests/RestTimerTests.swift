import Foundation
import Testing
@testable import LiftingCoachModel

private let noon = Date(timeIntervalSince1970: 1_770_000_000)
private func later(_ seconds: TimeInterval) -> Date { noon.addingTimeInterval(seconds) }

private func timer(_ seconds: Int) -> RestTimer {
    RestTimer(
        exerciseID: UUID(),
        setID: UUID(),
        exerciseName: "Barbell Bench Press",
        seconds: seconds,
        from: noon
    )
}

@Suite("Rest timer")
struct RestTimerTests {

    @Test("Counts down to the end of the prescribed rest")
    func countsDown() {
        let rest = timer(120)

        #expect(rest.remaining(at: noon) == 120)
        #expect(rest.remaining(at: later(45)) == 75)
        #expect(!rest.isOver(at: later(119)))
    }

    @Test("Stops at zero instead of running past it")
    func doesNotOverrun() {
        let rest = timer(120)

        // The whole point: a rest timer reports rest *owed*. Counting on past
        // the end turns it into a stopwatch measuring how late the lifter is,
        // which is a different (and unasked-for) instrument.
        #expect(rest.remaining(at: later(120)) == 0)
        #expect(rest.remaining(at: later(600)) == 0)
        #expect(rest.isOver(at: later(120)))
        #expect(rest.progress(at: later(600)) == 1)
    }

    @Test("Progress runs 0 to 1 across the rest period")
    func progressSpansThePeriod() {
        let rest = timer(200)

        #expect(rest.progress(at: noon) == 0)
        #expect(rest.progress(at: later(50)) == 0.25)
        #expect(rest.progress(at: later(100)) == 0.5)
    }

    @Test("A rest prescription of nothing is already over")
    func zeroLengthRest() {
        let rest = timer(0)

        #expect(rest.isOver(at: noon))
        #expect(rest.remaining(at: noon) == 0)
        // Guards the divide in `progress` — `duration` is floored at a second.
        #expect(rest.progress(at: noon) == 1)
    }

    @Test("Adding time extends the countdown and the bar with it")
    func adjustUpwards() {
        var rest = timer(120)
        rest.adjust(by: 30, now: later(60))

        #expect(rest.remaining(at: later(60)) == 90)
        // The denominator grew too, so the fill stays put rather than jumping
        // backwards under the lifter.
        #expect(rest.duration == 150)
        #expect(rest.progress(at: later(60)) == 0.4)
        #expect(!rest.hasExpired)
    }

    @Test("Cutting rest shorter than the time already spent lands on zero")
    func adjustBelowElapsed() {
        var rest = timer(120)
        rest.adjust(by: -30, now: later(110))

        // 120 − 30 = 90 seconds of rest, but 110 have already passed. Rest owed
        // is none, not negative twenty.
        #expect(rest.remaining(at: later(110)) == 0)
        #expect(rest.isOver(at: later(110)))
        #expect(rest.hasExpired)
    }

    @Test("Setting the remaining time replaces what's left on the clock")
    func setRemaining() {
        var rest = timer(120)
        rest.setRemaining(180, now: later(60))

        #expect(rest.remaining(at: later(60)) == 180)
        #expect(!rest.hasExpired)
        // `startedAt` stays where it was, so the bar still measures this rest
        // period from when it actually began rather than restarting.
        #expect(rest.duration == 240)
    }

    @Test("Setting the remaining time to nothing ends the rest")
    func setRemainingToZero() {
        var rest = timer(120)
        rest.setRemaining(0, now: later(30))

        #expect(rest.remaining(at: later(30)) == 0)
        #expect(rest.isOver(at: later(30)))
        #expect(rest.hasExpired)
    }

    @Test("Putting time back on an expired clock revives it")
    func setRemainingRevives() {
        var rest = timer(60)
        rest.hasExpired = true
        rest.setRemaining(90, now: later(60))

        #expect(rest.remaining(at: later(60)) == 90)
        #expect(!rest.hasExpired)
    }

    @Test("Adding time to a finished timer puts it back on the clock")
    func adjustRevivesAnExpiredTimer() {
        var rest = timer(60)
        rest.hasExpired = true
        rest.adjust(by: 30, now: later(60))

        // "One more minute" after the buzzer is a normal thing to want, and the
        // timer has to stop claiming it's done for the row to read right.
        #expect(rest.remaining(at: later(60)) == 30)
        #expect(!rest.hasExpired)
    }
}

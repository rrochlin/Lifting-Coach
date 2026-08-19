import Foundation
import Testing
@testable import LiftingCoachModel

/// Pinned to UTC: every assertion here is about which calendar day something
/// lands on, and `Calendar.current` would make that depend on the machine.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

/// A three-week block, Mon/Wed of each week, starting Aug 17 2026 (a Monday).
private func block(startingOn start: Date = day(2026, 8, 17)) -> WorkoutBlock {
    var program: [Date: [PlannedWorkout]] = [:]
    for week in 0..<3 {
        for offset in [0, 2] {
            let date = calendar.date(byAdding: .day, value: week * 7 + offset, to: start)!
            program[date] = [
                PlannedWorkout(
                    date: date,
                    exercises: [[
                        PlannedExercise(
                            exercise: ExerciseCatalog.seed[0],
                            sets: [PlannedSet(reps: 5, type: .working)]
                        ),
                    ]],
                    notes: "Week \(week + 1) day \(offset == 0 ? 1 : 2)"
                ),
            ]
        }
    }
    return WorkoutBlock(
        program: program,
        startDate: start,
        endDate: calendar.date(byAdding: .day, value: 20, to: start),
        notes: "Block 1"
    )
}

@Suite("WorkoutBlock scheduling")
struct WorkoutBlockScheduleTests {

    @Test("Rescheduling moves every programmed day by the same offset")
    func movesProgramWithStart() {
        let original = block()
        let moved = original.rescheduled(to: day(2026, 7, 13), calendar: calendar)

        #expect(moved.startDate == day(2026, 7, 13))
        #expect(moved.program?.count == original.program?.count)

        let originalDays = (original.program ?? [:]).keys.sorted()
        let movedDays = (moved.program ?? [:]).keys.sorted()
        for (before, after) in zip(originalDays, movedDays) {
            #expect(calendar.dateComponents([.day], from: after, to: before).day == 35)
        }
    }

    /// The case this was built for: a program loaded onto today's date when the
    /// lifter is really five weeks into it. Moving the start back five weeks has
    /// to make today read as week 6, not relabel week 1.
    @Test("Moving the start back five weeks puts today in week 6")
    func rescheduleLandsTodayInTheRightWeek() {
        let original = block(startingOn: day(2026, 8, 17))
        #expect(original.progress(asOf: day(2026, 8, 19), calendar: calendar)?.weekIndex == 1)

        let moved = original.rescheduled(to: day(2026, 7, 13), calendar: calendar)

        #expect(moved.progress(asOf: day(2026, 8, 19), calendar: calendar)?.weekIndex == 6)
        // And week 6's programming is genuinely there rather than being a label
        // over week 1's — the day that was week 1 Monday is now July 13.
        #expect(moved.program?[day(2026, 7, 13)]?.first?.notes == "Week 1 day 1")
    }

    @Test("A moved day's own date matches the day it's filed under")
    func movesWorkoutDatesWithTheirKeys() {
        let moved = block().rescheduled(to: day(2026, 7, 13), calendar: calendar)

        for (key, workouts) in moved.program ?? [:] {
            for workout in workouts {
                #expect(workout.date == key)
            }
        }
    }

    @Test("Rescheduling preserves the block's length")
    func preservesLength() {
        let original = block()
        let moved = original.rescheduled(to: day(2026, 7, 13), calendar: calendar)

        #expect(moved.plannedWeeks(calendar: calendar) == original.plannedWeeks(calendar: calendar))
        #expect(moved.endDate == day(2026, 8, 2))
    }

    @Test("Rescheduling leaves prescriptions alone")
    func preservesPrescriptions() {
        let original = block()
        let moved = original.rescheduled(to: day(2026, 7, 13), calendar: calendar)

        let before = (original.program ?? [:]).keys.sorted().compactMap {
            original.program?[$0]?.first?.allSets.first
        }
        let after = (moved.program ?? [:]).keys.sorted().compactMap {
            moved.program?[$0]?.first?.allSets.first
        }
        #expect(before == after)
    }

    @Test("Rescheduling to the same day changes nothing")
    func noOpReschedule() {
        let original = block()
        #expect(original.rescheduled(to: day(2026, 8, 17), calendar: calendar) == original)
    }

    /// A block with no `startDate` still has a first programmed day, and that's
    /// what "move the program" measures from — the same fallback
    /// `programmedWeeks` uses to group an unscheduled block.
    @Test("An unscheduled block anchors on its earliest programmed day")
    func anchorsOnEarliestDayWithoutStartDate() {
        var original = block()
        original.startDate = nil
        original.endDate = nil

        #expect(original.scheduleAnchor(calendar: calendar) == day(2026, 8, 17))

        let moved = original.rescheduled(to: day(2026, 7, 13), calendar: calendar)
        #expect(moved.startDate == day(2026, 7, 13))
        #expect(moved.program?[day(2026, 7, 13)]?.first?.notes == "Week 1 day 1")
    }

    @Test("Length is read from the dates and written back to endDate")
    func lengthRoundTrips() {
        let original = block()
        #expect(original.plannedWeeks(calendar: calendar) == 3)

        let longer = original.withLength(weeks: 12, calendar: calendar)
        #expect(longer.plannedWeeks(calendar: calendar) == 12)
        #expect(longer.endDate == day(2026, 11, 8))
        // Length is the horizon, not the schedule: nothing programmed moves.
        #expect(longer.program == original.program)
    }

    @Test("A block with no planned end has no length")
    func noLengthWithoutEndDate() {
        var original = block()
        original.endDate = nil
        #expect(original.plannedWeeks(calendar: calendar) == nil)
    }

    /// The other reading of a start-date change, and the reason the editor asks
    /// rather than assuming: restating the start alone leaves the days where
    /// they are, which moves which week they fall in.
    @Test("Restating the start without moving days changes which week a day is in")
    func restatingStartRelabelsWeeks() {
        var original = block()
        let firstDay = day(2026, 8, 17)
        #expect(original.programmedWeeks(calendar: calendar).first?.index == 1)

        original.startDate = day(2026, 7, 13)
        let weeks = original.programmedWeeks(calendar: calendar)
        #expect(weeks.first?.index == 6)
        #expect(weeks.first?.days.first == firstDay)
    }
}

import Foundation
import Testing
@testable import LiftingCoachModel

/// Pinned to UTC: "which day is this" is the thing under test, and
/// `Calendar.current` would make it depend on the machine's timezone.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

private func block(start: Date?, days: [Date]) -> WorkoutBlock {
    var program: [Date: [PlannedWorkout]] = [:]
    for day in days {
        program[day, default: []].append(PlannedWorkout(date: day))
    }
    return WorkoutBlock(program: program, startDate: start)
}

@Suite("Block programmed weeks")
struct WorkoutBlockWeekTests {

    @Test("Days group into 7-day weeks counted from the block's start")
    func groupsIntoWeeks() {
        // Thursday start, deliberately: weeks run Thu-Wed because that's what
        // the block's author meant, not Mon-Sun because that's what the
        // calendar says.
        let start = day(2026, 1, 1)
        let block = block(start: start, days: [
            day(2026, 1, 1),   // week 1, day 1
            day(2026, 1, 7),   // week 1, day 7
            day(2026, 1, 8),   // week 2, day 1
            day(2026, 1, 20),  // week 3
        ])

        let weeks = block.programmedWeeks(calendar: calendar)

        #expect(weeks.map(\.index) == [1, 2, 3])
        #expect(weeks[0].days == [day(2026, 1, 1), day(2026, 1, 7)])
        #expect(weeks[1].days == [day(2026, 1, 8)])
        #expect(weeks[2].days == [day(2026, 1, 20)])
    }

    @Test("Weeks with nothing programmed don't appear")
    func skipsEmptyWeeks() {
        let block = block(start: day(2026, 1, 1), days: [
            day(2026, 1, 1),
            day(2026, 1, 22),  // week 4 — weeks 2 and 3 are empty
        ])

        #expect(block.programmedWeeks(calendar: calendar).map(\.index) == [1, 4])
    }

    @Test("The week index matches the one progress reports")
    func agreesWithProgress() {
        // The planner highlights "the current week" by comparing these two, so
        // they have to be counted the same way.
        let start = day(2026, 1, 1)
        let block = block(start: start, days: [day(2026, 1, 20)])

        let week = block.programmedWeeks(calendar: calendar).first
        let progress = block.progress(asOf: day(2026, 1, 20), calendar: calendar)

        #expect(week?.index == progress?.weekIndex)
    }

    @Test("A day programmed before the block starts lands in an earlier week, not week 1")
    func daysBeforeTheStartDoNotFoldIntoWeekOne() {
        // Integer division truncates toward zero, so -3/7 == 0 would put a day
        // three days early in week 1 alongside the real first week.
        let block = block(start: day(2026, 1, 8), days: [
            day(2026, 1, 5),
            day(2026, 1, 8),
        ])

        let weeks = block.programmedWeeks(calendar: calendar)
        #expect(weeks.map(\.index) == [0, 1])
        #expect(weeks[0].days == [day(2026, 1, 5)])
    }

    @Test("An unscheduled block anchors on its earliest programmed day")
    func anchorsOnFirstDayWithoutAStartDate() {
        let block = block(start: nil, days: [day(2026, 3, 2), day(2026, 3, 10)])

        let weeks = block.programmedWeeks(calendar: calendar)
        #expect(weeks.map(\.index) == [1, 2])
    }

    @Test("A block with nothing programmed has no weeks")
    func emptyBlock() {
        #expect(WorkoutBlock(startDate: day(2026, 1, 1)).programmedWeeks(calendar: calendar).isEmpty)
    }

    @Test("A day whose workouts were all removed isn't counted as programmed")
    func dropsDaysWithNoWorkouts() {
        // PlanStore can leave an empty array behind after the last workout on a
        // day is deleted; an empty week header would read as a bug.
        var block = block(start: day(2026, 1, 1), days: [day(2026, 1, 1)])
        block.program?[day(2026, 1, 9)] = []

        #expect(block.programmedWeeks(calendar: calendar).map(\.index) == [1])
    }
}

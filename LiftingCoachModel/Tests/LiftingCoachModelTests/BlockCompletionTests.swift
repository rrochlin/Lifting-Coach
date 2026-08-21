import Foundation
import Testing
@testable import LiftingCoachModel

/// Pinned to UTC: "was this logged on that day" is the thing under test, and
/// `Calendar.current` would make it depend on the machine's timezone.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

private func at(_ date: Date, hour: Int) -> Date {
    calendar.date(byAdding: .hour, value: hour, to: date)!
}

private func session(_ startedAt: Date, sets: Int) -> BlockCompletion.Session {
    BlockCompletion.Session(id: UUID(), startedAt: startedAt, setCount: sets)
}

@Suite("Block completion")
struct BlockCompletionTests {

    @Test("A session lands on the calendar day it started, whatever time it was")
    func bucketsByDay() {
        let monday = day(2026, 3, 2)
        let completion = BlockCompletion(
            sessions: [session(at(monday, hour: 19), sets: 24)],
            calendar: calendar
        )

        #expect(completion.wasTrained(on: monday))
        // Looked up by any instant in the day, not only by its start.
        #expect(completion.wasTrained(on: at(monday, hour: 6)))
        #expect(!completion.wasTrained(on: day(2026, 3, 3)))
    }

    @Test("Sets sum across every session on a day")
    func sumsSetsWithinADay() {
        let saturday = day(2026, 3, 7)
        let completion = BlockCompletion(
            sessions: [
                session(at(saturday, hour: 7), sets: 18),
                session(at(saturday, hour: 18), sets: 6),
            ],
            calendar: calendar
        )

        #expect(completion.setCount(on: saturday) == 24)
        #expect(completion.sessions(on: saturday).count == 2)
        // Earliest first, so the day reads in the order it was trained.
        #expect(completion.sessions(on: saturday).map(\.setCount) == [18, 6])
    }

    @Test("An untrained day reports zero rather than nothing")
    func untrainedDayIsZero() {
        let completion = BlockCompletion(calendar: calendar)

        #expect(completion.setCount(on: day(2026, 3, 2)) == 0)
        #expect(completion.sessions(on: day(2026, 3, 2)).isEmpty)
        #expect(!completion.wasTrained(on: day(2026, 3, 2)))
    }

    @Test("The rollup counts trained days, not sessions")
    func rollupCountsDays() {
        let week = [day(2026, 3, 2), day(2026, 3, 3), day(2026, 3, 4), day(2026, 3, 7)]
        let completion = BlockCompletion(
            sessions: [
                session(at(week[0], hour: 17), sets: 20),
                // Two on one day is still one trained day out of the week.
                session(at(week[3], hour: 7), sets: 12),
                session(at(week[3], hour: 18), sets: 8),
            ],
            calendar: calendar
        )

        #expect(completion.trainedDays(among: week) == 2)
    }

    @Test("A session on an unprogrammed day doesn't inflate the rollup")
    func ignoresDaysOutsideTheProgram() {
        // Logged on the Wednesday, which this block programs nothing on. It's
        // real training and it belongs in History; it is not evidence that a
        // programmed day was done.
        let programmed = [day(2026, 3, 2), day(2026, 3, 5)]
        let completion = BlockCompletion(
            sessions: [session(at(day(2026, 3, 4), hour: 17), sets: 22)],
            calendar: calendar
        )

        #expect(completion.trainedDays(among: programmed) == 0)
        #expect(completion.wasTrained(on: day(2026, 3, 4)))
    }

    @Test("Duplicate days in a rollup collapse")
    func rollupDeduplicatesDays() {
        let monday = day(2026, 3, 2)
        let completion = BlockCompletion(
            sessions: [session(at(monday, hour: 17), sets: 20)],
            calendar: calendar
        )

        // A day with two *planned* workouts appears twice in the caller's list;
        // it is still one day of the week.
        #expect(completion.trainedDays(among: [monday, monday]) == 1)
    }
}

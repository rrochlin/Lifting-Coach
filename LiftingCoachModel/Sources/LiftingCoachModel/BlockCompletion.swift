import Foundation

/// Which of a block's programmed days have actually been trained.
///
/// The planner has always shown one half of a block — what was *asked for*.
/// Nothing on the screen said a day had been done, which on a 12-week program
/// makes six weeks of finished work indistinguishable from six weeks of
/// intentions.
///
/// **Days are matched by calendar date, not by identity, and that limitation is
/// deliberate rather than overlooked.** `Workout.blockId` is never written —
/// the tracker saves without one — so nothing records that a given logged
/// session *was* Tuesday's programmed squat day. Home's adherence readout
/// already joins the two sides by date, and this joins them the same way so the
/// planner and the homepage cannot disagree about the same block.
///
/// The consequence is that an ad-hoc session on a programmed day reads as that
/// day having been trained. What keeps this honest is that the count is
/// reported rather than a verdict: the screen shows logged sets against
/// programmed sets and lets the lifter read the difference, instead of deciding
/// on their behalf that a day counts (Core Tenets §1, §10).
///
/// Pure and calendar-injected for the usual reason — "same day" must not depend
/// on the machine's timezone, which is the thing under test.
public struct BlockCompletion: Hashable, Sendable {

    /// A logged session, reduced to the two facts the planner needs. Built from
    /// a lightweight summary rather than a hydrated `Workout`: drawing a block
    /// must not pull in every set of every session inside it.
    public struct Session: Hashable, Sendable {
        public var id: UUID
        public var startedAt: Date
        /// Sets actually completed in it.
        public var setCount: Int

        public init(id: UUID, startedAt: Date, setCount: Int) {
            self.id = id
            self.startedAt = startedAt
            self.setCount = setCount
        }
    }

    private let byDay: [Date: [Session]]
    private let calendar: Calendar

    public init(sessions: [Session] = [], calendar: Calendar = .current) {
        self.calendar = calendar
        byDay = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
    }

    /// Sessions logged on a calendar day, earliest first.
    public func sessions(on day: Date) -> [Session] {
        (byDay[calendar.startOfDay(for: day)] ?? []).sorted { $0.startedAt < $1.startedAt }
    }

    /// Whether anything at all was logged on a day. The weakest possible claim,
    /// and the one the day panel's marker makes.
    public func wasTrained(on day: Date) -> Bool {
        !(byDay[calendar.startOfDay(for: day)] ?? []).isEmpty
    }

    /// Completed sets logged on a day, across every session in it.
    ///
    /// Sets rather than sessions, matching Home: a day cut short after two of
    /// five exercises is partial, and counting workouts would record it as full
    /// credit.
    public func setCount(on day: Date) -> Int {
        (byDay[calendar.startOfDay(for: day)] ?? []).reduce(0) { $0 + $1.setCount }
    }

    /// How many of `days` were trained — the week and block rollups.
    ///
    /// Counts *days*, not sessions, so a Saturday with a morning and an evening
    /// session is one trained day out of the week's six. Duplicate dates in the
    /// input collapse for the same reason.
    public func trainedDays(among days: [Date]) -> Int {
        Set(days.map { calendar.startOfDay(for: $0) }).filter { wasTrained(on: $0) }.count
    }
}

import Foundation

/// A training block: a bounded span of time (e.g. a 6-week strength cycle) made
/// up of scheduled workouts, plus notes on the block's objectives and a running
/// journal.
public struct WorkoutBlock: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Logged workouts, keyed by the start of each calendar day. Always
    /// normalize with `Calendar.startOfDay` before using as a key. The value is
    /// an array to support multiple workouts on the same day (e.g. AM/PM).
    public var workouts: [Date: [Workout]]?
    /// The programmed side: all planned activity, keyed the same way.
    public var program: [Date: [PlannedWorkout]]?
    public var startDate: Date?
    /// Planned end — a target, not authoritative. Blocks routinely run past this
    /// (slipped schedules, unlogged deload weeks), so nothing should treat
    /// crossing `endDate` as "the block is over". See `WorkoutPlan.currentBlock`
    /// for how the current block is actually derived.
    public var endDate: Date?
    public var notes: String?
    public var journal: String?
    /// Fallback rest time (seconds) per `SetType`, used when a `PlannedSet`
    /// doesn't specify its own.
    public var defaultRestTimes: [SetType: Int]?

    public init(
        id: UUID = UUID(),
        workouts: [Date: [Workout]]? = nil,
        program: [Date: [PlannedWorkout]]? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        notes: String? = nil,
        journal: String? = nil,
        defaultRestTimes: [SetType: Int]? = nil
    ) {
        self.id = id
        self.workouts = workouts
        self.program = program
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.journal = journal
        self.defaultRestTimes = defaultRestTimes
    }

    /// Rest time in seconds for a planned set: the set's own override, then this
    /// block's default for that set type, then the app-level fallback.
    public func restTime(for set: PlannedSet, appDefault: Int = 120) -> Int {
        if let explicit = set.restTime { return explicit }
        if let type = set.type, let blockDefault = defaultRestTimes?[type] {
            return blockDefault
        }
        return appDefault
    }

    /// Workouts logged on a given calendar day.
    public func workouts(on day: Date, calendar: Calendar = .current) -> [Workout] {
        workouts?[calendar.startOfDay(for: day)] ?? []
    }

    /// Workouts programmed for a given calendar day.
    public func program(on day: Date, calendar: Calendar = .current) -> [PlannedWorkout] {
        program?[calendar.startOfDay(for: day)] ?? []
    }

    /// Calendar progress through the block, for the homepage's "week 3 of 6,
    /// day 15" readout. Returns `nil` if the block has no `startDate`.
    ///
    /// `totalWeeks` is `nil` when there's no `endDate` to measure against, and
    /// `dayIndex`/`weekIndex` keep counting past `endDate` rather than clamping —
    /// a block that runs long should read "week 7 of 6", not silently stop.
    public func progress(asOf date: Date = Date(), calendar: Calendar = .current) -> Progress? {
        guard let startDate else { return nil }
        let start = calendar.startOfDay(for: startDate)
        let today = calendar.startOfDay(for: date)
        guard let elapsed = calendar.dateComponents([.day], from: start, to: today).day else {
            return nil
        }

        let dayIndex = elapsed + 1
        let weekIndex = elapsed / 7 + 1

        var totalWeeks: Int?
        if let endDate {
            let end = calendar.startOfDay(for: endDate)
            if let span = calendar.dateComponents([.day], from: start, to: end).day {
                totalWeeks = span / 7 + 1
            }
        }

        return Progress(dayIndex: dayIndex, weekIndex: weekIndex, totalWeeks: totalWeeks)
    }

    public struct Progress: Hashable, Sendable {
        /// 1-based day within the block. Negative/zero before the block starts.
        public var dayIndex: Int
        /// 1-based week within the block.
        public var weekIndex: Int
        /// `nil` when the block has no planned `endDate`.
        public var totalWeeks: Int?
    }

    /// The block's programmed days, grouped into its training weeks.
    ///
    /// A 12-week program is ~70 programmed days; a flat list of them is
    /// unreadable, and the week is the unit the program is actually written in
    /// (`Week 5 Fri`), so it's the unit the planner navigates by.
    ///
    /// Weeks are counted from `startDate` in 7-day spans, *not* by calendar
    /// week — a block starting on a Wednesday runs Wed–Tue weeks, which is what
    /// its author meant. With no `startDate` the earliest programmed day
    /// anchors week 1 instead, so an unscheduled block still groups sensibly.
    /// Only weeks that have something programmed appear.
    public func programmedWeeks(calendar: Calendar = .current) -> [ProgrammedWeek] {
        let days = (program ?? [:])
            .filter { !$0.value.isEmpty }
            .keys
            .map { calendar.startOfDay(for: $0) }
            .sorted()
        guard let anchor = startDate.map({ calendar.startOfDay(for: $0) }) ?? days.first else {
            return []
        }

        var byWeek: [Int: [Date]] = [:]
        for day in days {
            guard let elapsed = calendar.dateComponents([.day], from: anchor, to: day).day else {
                continue
            }
            // Integer division truncates toward zero, so a day *before* the
            // anchor would land in week 1 alongside the first real week. Floor
            // it instead: a day programmed early belongs to week 0 or lower.
            let offset = elapsed >= 0 ? elapsed / 7 : (elapsed - 6) / 7
            byWeek[offset + 1, default: []].append(day)
        }

        return byWeek
            .map { ProgrammedWeek(index: $0.key, days: $0.value.sorted()) }
            .sorted { $0.index < $1.index }
    }

    /// One training week's worth of programmed days.
    public struct ProgrammedWeek: Hashable, Identifiable, Sendable {
        /// 1-based, counted from the block's start. Matches the `weekIndex` in
        /// `Progress`, so "the current week" is a direct comparison.
        public var index: Int
        public var days: [Date]

        public var id: Int { index }

        public init(index: Int, days: [Date]) {
            self.index = index
            self.days = days
        }
    }
}

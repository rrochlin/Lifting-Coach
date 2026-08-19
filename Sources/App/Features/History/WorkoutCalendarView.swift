import SwiftUI
import LiftingCoachModel
import LiftingCoachPersistence

/// One month of training at a time, as `Features/Workout History.md` specifies:
/// a calendar of dots, a dialog on touch, and an edit button in the dialog.
///
/// The list beside it answers "what have I been doing"; this answers "what did I
/// do in August, and where are the gaps" — which is a question about *shape*,
/// and a list can't show shape. Consistency, a missed Thursday, a week off: all
/// of it is a glance here and a scroll there.
///
/// **Dots carry no detail, on purpose.** The doc is explicit about it, and it's
/// right: a 7-column grid on a phone has room for a number and a mark, and
/// anything more turns a month into something you have to read rather than see.
/// Volume is the one exception — a day with three dots did three times the work
/// of a day with one, and that's a fact about the *shape* of the month too.
///
/// Fetching is per month and range-scoped (`WorkoutStore.fetchSummaries(from:to:)`)
/// rather than paged: a month is a bounded question, and 840 workouts of history
/// must never be walked to draw thirty days.
struct WorkoutCalendarView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Opens a workout in its own screen. The parent owns navigation, because
    /// the list beside this one pushes exactly the same destination.
    let onEdit: (UUID) -> Void

    @State private var month: Date = Calendar.current.startOfMonth(for: Date())
    @State private var summaries: [WorkoutSummary] = []
    @State private var selectedDay: SelectedDay?
    @State private var loadError: String?

    private var calendar: Calendar { .current }

    var body: some View {
        List {
            monthHeader
            if let loadError {
                Panel(accent: Theme.alert.opacity(0.5)) {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.alert)
                }
                .panelRow()
            }
            grid
            monthSummary
        }
        .listStyle(.plain)
        .screenGround()
        .task(id: month) {
            load()
            #if DEBUG
            openLaunchArgumentDay()
            #endif
        }
        // An overlay rather than a sheet, matching `themedConfirm`: the dialog
        // is about the day behind it, and a sheet that covers the month loses
        // the context the tap was made in.
        .overlay {
            if let selectedDay {
                DayDialog(
                    day: selectedDay.day,
                    summaries: selectedDay.summaries,
                    onEdit: { id in
                        self.selectedDay = nil
                        onEdit(id)
                    },
                    onDismiss: { self.selectedDay = nil }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: selectedDay?.day)
    }

    // MARK: - Month navigation

    private var monthHeader: some View {
        HStack(spacing: 12) {
            monthStep(-1, systemImage: "chevron.left")
            Text(month.formatted(.dateTime.month(.wide).year()).uppercased())
                .font(Theme.label)
                .tracking(1.6)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
            monthStep(1, systemImage: "chevron.right")
        }
        .padding(.vertical, 4)
        .panelRow()
    }

    private func monthStep(_ delta: Int, systemImage: String) -> some View {
        Button {
            guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return }
            month = calendar.startOfMonth(for: next)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.signal)
                .frame(width: 40, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private var grid: some View {
        Panel {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(weekdayLabels, id: \.self) { label in
                        Text(label)
                            .font(Theme.label)
                            .tracking(1.0)
                            .foregroundStyle(Theme.inkFaint)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            dayCell(day)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .panelRow()
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let workouts = summaries(on: day)
            DayCell(
                day: day,
                workoutCount: workouts.count,
                isToday: calendar.isDateInToday(day),
                onTap: workouts.isEmpty
                    ? nil
                    : { selectedDay = SelectedDay(day: day, summaries: workouts) }
            )
        } else {
            // A leading or trailing blank. Rendered rather than skipped so the
            // columns stay under their weekday headers.
            Color.clear.frame(height: 42)
        }
    }

    /// What the month came to, since the grid deliberately doesn't say.
    @ViewBuilder
    private var monthSummary: some View {
        let sets = summaries.reduce(0) { $0 + $1.completedSetCount }
        Panel {
            HStack {
                Readout(
                    label: "workouts",
                    value: "\(summaries.count)",
                    accent: summaries.isEmpty ? Theme.inkMuted : Theme.signal,
                    size: 17
                )
                Spacer(minLength: 24)
                Readout(label: "sets", value: "\(sets)", accent: Theme.inkMuted, size: 17)
            }
        }
        .panelRow()
    }

    // MARK: - Data

    private func load() {
        guard let range = calendar.monthRange(of: month) else { return }
        do {
            summaries = try environment.workouts.fetchSummaries(from: range.start, to: range.end)
            loadError = nil
        } catch {
            summaries = []
            loadError = error.localizedDescription
        }
    }

    #if DEBUG
    /// `-openCalendarDay 18`. Latched, like every other one of these: `.task`
    /// re-runs whenever the month changes, and a dialog that reopens itself is
    /// indistinguishable from a bug in the cell tap.
    @State private var didOpenLaunchDay = false

    private func openLaunchArgumentDay() {
        guard !didOpenLaunchDay, let dayOfMonth = LaunchArguments.calendarDay else { return }
        didOpenLaunchDay = true
        guard let day = calendar.date(bySetting: .day, value: dayOfMonth, of: month) else { return }
        let workouts = summaries(on: day)
        guard !workouts.isEmpty else { return }
        selectedDay = SelectedDay(day: day, summaries: workouts)
    }
    #endif

    private func summaries(on day: Date) -> [WorkoutSummary] {
        summaries.filter {
            guard let start = $0.startTime else { return false }
            return calendar.isDate(start, inSameDayAs: day)
        }
    }

    /// The month laid out as rows of seven, padded to the weekday it starts on.
    private var weeks: [[Date?]] {
        guard let range = calendar.monthRange(of: month),
              let dayCount = calendar.range(of: .day, in: .month, for: month)?.count
        else { return [] }

        // `firstWeekday` is 1-based and locale-dependent — a grid hard-coded to
        // Sunday-first is wrong in most of the world and, more to the point,
        // wrong against the weekday headers right above it.
        let leading = (calendar.component(.weekday, from: range.start) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: range.start))
        }
        while cells.count % 7 != 0 { cells.append(nil) }

        return stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<min($0 + 7, cells.count)])
        }
    }

    private var weekdayLabels: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[($0 + first) % 7].uppercased() }
    }

    /// The day whose dialog is up. Carries its summaries so the dialog renders
    /// from what was tapped rather than re-querying.
    private struct SelectedDay: Equatable {
        let day: Date
        let summaries: [WorkoutSummary]
    }
}

// MARK: - Day cell

/// One square: the date, and a mark for each workout logged on it.
private struct DayCell: View {
    let day: Date
    let workoutCount: Int
    let isToday: Bool
    /// `nil` on a day with nothing logged — an empty day is not a control, and
    /// a dialog saying "no workouts" is a dead end.
    let onTap: (() -> Void)?

    var body: some View {
        Button { onTap?() } label: {
            VStack(spacing: 3) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(Theme.data(14, weight: isToday ? .bold : .regular))
                    .foregroundStyle(numberColor)
                HStack(spacing: 2) {
                    // Capped at three: past that the dots stop being countable
                    // and start being a smear, and a fourth session in one day
                    // is not a distinction the grid needs to draw.
                    ForEach(0..<min(workoutCount, 3), id: \.self) { _ in
                        Circle()
                            .fill(Theme.signal)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .background(isToday ? Theme.panelRaised : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isToday ? Theme.live.opacity(0.6) : .clear, lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private var numberColor: Color {
        if isToday { return Theme.live }
        return workoutCount > 0 ? Theme.ink : Theme.inkFaint
    }
}

// MARK: - Day dialog

/// What was done on one day, and the way into correcting it.
///
/// The summary the doc asks for: enough to recognise the session without
/// opening it, and an EDIT that goes straight to the editable screen rather
/// than to a read-only one with another button on it.
private struct DayDialog: View {
    let day: Date
    let summaries: [WorkoutSummary]
    let onEdit: (UUID) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.void.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            Panel(accent: Theme.signal.opacity(0.5)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                            .font(Theme.label)
                            .tracking(1.4)
                            .foregroundStyle(Theme.inkMuted)
                        Spacer(minLength: 8)
                        Button("CLOSE", action: onDismiss)
                            .font(Theme.label)
                            .tracking(1.2)
                            .foregroundStyle(Theme.inkMuted)
                            .buttonStyle(.plain)
                    }

                    ForEach(summaries) { summary in
                        if summary.id != summaries.first?.id {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                        workoutBlock(summary)
                    }
                }
            }
            .padding(.horizontal, 28)
        }
    }

    private func workoutBlock(_ summary: WorkoutSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.notes?.isEmpty == false ? summary.notes! : "Workout")
                    .font(Theme.heading)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let start = summary.startTime {
                    Text(start.formatted(date: .omitted, time: .shortened))
                        .font(Theme.data(13))
                        .foregroundStyle(Theme.inkFaint)
                        .fixedSize()
                }
            }

            // Most of the imported log is called "Afternoon Workout", which is
            // true and useless — the contents are what identifies a session.
            if !summary.exerciseNames.isEmpty {
                Text(summary.exerciseNames.joined(separator: " · "))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                Text("\(summary.completedSetCount) sets")
                    .font(Theme.data(13))
                    .foregroundStyle(Theme.inkMuted)
                if let source = summary.source {
                    Chip(text: source, color: Theme.inkFaint)
                }
                Spacer(minLength: 8)
                Button("EDIT") { onEdit(summary.id) }
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.signal)
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Calendar helpers

extension Calendar {
    /// The first instant of the month containing `date`.
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }

    /// First and last day of the month containing `date`.
    func monthRange(of date: Date) -> (start: Date, end: Date)? {
        let start = startOfMonth(for: date)
        guard let dayCount = range(of: .day, in: .month, for: start)?.count,
              let end = self.date(byAdding: .day, value: dayCount - 1, to: start)
        else { return nil }
        return (start, end)
    }
}

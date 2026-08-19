import SwiftUI
import LiftingCoachModel
import LiftingCoachPersistence

/// Logged history, two ways: a month calendar and a reverse-chronological list.
///
/// `Features/Workout History.md` specifies the calendar — dots, one month at a
/// time, a dialog on touch with an edit button — so that's the default. The list
/// stays because the two answer different questions: the calendar shows the
/// *shape* of a month (consistency, a missed Thursday, a week off), and the list
/// is how you walk backwards through five years. Neither is a worse version of
/// the other, so both are here and the toggle is one tap.
///
/// Both read `WorkoutSummary` rather than hydrating workouts. That's what makes
/// either survivable against a real log: 840 workouts and 14,520 sets, where the
/// original version fetched a two-year window through `WorkoutStore.fetch(from:to:)`
/// and **hydrated every set of every workout** — thousands of queries to draw a
/// list of dates and names. Exactly one workout is hydrated, when you open it.
struct WorkoutHistoryView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var summaries: [WorkoutSummary] = []
    @State private var loadError: String?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var mode: HistoryMode = .calendar
    /// Not `#if DEBUG` any more: the calendar's day dialog navigates from a
    /// button inside an overlay, which needs a path to push onto rather than a
    /// `NavigationLink`.
    @State private var path: [UUID] = []
    /// Which workout was opened from the calendar, and therefore wants the
    /// editor rather than the reader.
    @State private var editingFromCalendar: UUID?
    #if DEBUG
    /// Latched, so returning from the pushed screen doesn't re-push it. `.task`
    /// re-runs on every tab selection, and without this the detail screen
    /// reopens itself, which is indistinguishable from a bug in the row tap.
    @State private var didOpenDebugDetail = false
    #endif

    /// A page is sized to comfortably overfill a screen, so the "load more"
    /// trigger at the bottom is reached by scrolling rather than on appearance.
    private let pageSize = 40

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch mode {
                case .calendar:
                    WorkoutCalendarView { id in
                        editingFromCalendar = id
                        path = [id]
                    }
                case .list:
                    listContent
                }
            }
            .navigationTitle("History")
            .toolbar { modeToggle }
            .navigationDestination(for: UUID.self) { id in
                // Editing or deleting a workout invalidates the row that opened
                // it — a corrected title, a different set count, or a workout
                // that is no longer there at all. Reloading exactly the pages
                // already on screen keeps the lifter's scroll position, which
                // re-paging from the top would throw away.
                WorkoutDetailView(
                    workoutID: id,
                    onChange: reloadLoadedPages,
                    startsEditing: editingFromCalendar == id
                )
            }
        }
    }

    /// Calendar or list, and nothing else in the toolbar — the two are the same
    /// data, so this is a lens, not a filter.
    @ToolbarContentBuilder
    private var modeToggle: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $mode) {
                Image(systemName: "calendar").tag(HistoryMode.calendar)
                Image(systemName: "list.bullet").tag(HistoryMode.list)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var listContent: some View {
        List {
            if let loadError {
                Panel(accent: Theme.alert.opacity(0.5)) {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.alert)
                }
                .panelRow()
            } else if summaries.isEmpty && !isLoading {
                Panel {
                    Text("No workouts logged yet.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.inkMuted)
                }
                .panelRow()
            } else {
                ForEach(months, id: \.key) { month in
                    SectionLabel(text: month.label, accent: Theme.signal)
                        .panelRow()
                    ForEach(month.summaries) { summary in
                        NavigationLink(value: summary.id) {
                            WorkoutHistoryRow(summary: summary)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            // A row opens the reader. Only the calendar's
                            // dialog, which has its own EDIT, asks for the
                            // editor — cleared here so a row tapped after one
                            // doesn't inherit it.
                            editingFromCalendar = nil
                        })
                        .buttonStyle(.plain)
                        .panelRow()
                    }
                }

                if hasMore {
                    // Appearing is what pages: the row only reaches the
                    // screen if the lifter scrolled to it.
                    loadMoreRow
                        .panelRow()
                        .onAppear { load(more: true) }
                }
            }
        }
        .listStyle(.plain)
        .screenGround()
        .refreshable { load(more: false) }
        .task {
            // `.task` re-runs on every tab selection; reloading a 40-row
            // page each time would throw away how far the lifter scrolled.
            if summaries.isEmpty { load(more: false) }
            #if DEBUG
            openDebugDetailIfRequested()
            #endif
        }
    }

    #if DEBUG
    private func openDebugDetailIfRequested() {
        guard !didOpenDebugDetail, let index = LaunchArguments.workoutDetailIndex else { return }
        didOpenDebugDetail = true
        // This flag names a workout by its position in the list, so it means
        // the list.
        mode = .list
        // Page far enough in to reach the requested workout — the interesting
        // ones to look at (a cardio session, a superset) are rarely in the
        // first forty.
        while summaries.count <= index && hasMore { load(more: true) }
        guard summaries.indices.contains(index) else { return }
        path = [summaries[index].id]
    }
    #endif

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            Text("LOADING")
                .font(Theme.label)
                .tracking(1.4)
                .foregroundStyle(Theme.inkFaint)
            Spacer()
        }
        .padding(.vertical, 10)
    }

    /// Summaries grouped into months, newest first, order preserved.
    private var months: [(key: Date, label: String, summaries: [WorkoutSummary])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var grouped: [Date: [WorkoutSummary]] = [:]

        for summary in summaries {
            guard let start = summary.startTime else { continue }
            let components = calendar.dateComponents([.year, .month], from: start)
            guard let month = calendar.date(from: components) else { continue }
            if grouped[month] == nil { order.append(month) }
            grouped[month, default: []].append(summary)
        }

        return order.map { month in
            (
                key: month,
                label: month.formatted(.dateTime.month(.wide).year()),
                summaries: grouped[month] ?? []
            )
        }
    }

    /// Re-fetches as many summaries as are currently displayed, in one bounded
    /// query. A deleted workout shortens the list by one and pulls the next
    /// older workout up into its place, which is what the log now says.
    private func reloadLoadedPages() {
        guard !summaries.isEmpty else { return load(more: false) }
        do {
            let requested = summaries.count
            let page = try environment.workouts.fetchSummaries(limit: requested)
            summaries = page
            // A short page means the log ran out inside what was already on
            // screen. A full one says nothing new, so the previous answer
            // stands — `requested` has to be read before `summaries` is
            // replaced, or the comparison is trivially true and the paging
            // trigger never turns off.
            hasMore = hasMore && page.count == requested
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func load(more: Bool) {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let before = more ? summaries.last?.startTime : nil
            let page = try environment.workouts.fetchSummaries(limit: pageSize, before: before)
            if more {
                summaries += page
            } else {
                summaries = page
            }
            // A short page is the end of the log; there's nothing after it to
            // ask for, and leaving the trigger on screen would spin forever.
            hasMore = page.count == pageSize
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            hasMore = false
        }
    }
}

/// Which lens History is showing. `Codable`-free and view-local: it's a
/// preference for the length of a visit, not something worth persisting.
enum HistoryMode: Hashable {
    case calendar
    case list
}

private struct WorkoutHistoryRow: View {
    let summary: WorkoutSummary

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(dateText)
                        .font(Theme.label)
                        .tracking(1.2)
                        .foregroundStyle(Theme.signal)
                    Spacer(minLength: 8)
                    if let durationText {
                        Text(durationText)
                            .font(Theme.label)
                            .tracking(1.2)
                            .foregroundStyle(Theme.inkFaint)
                    }
                }
                Text(title)
                    .font(Theme.heading)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                // Shown beneath the title rather than instead of it. Most of
                // the imported log is called "Afternoon Workout" — Strong's
                // autogenerated name — which is true and says nothing, and the
                // alternative was a hardcoded list of names to treat as
                // meaningless. What was actually done answers it without
                // anything having to judge the title.
                if let contents, contents != title {
                    Text(contents)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text("\(summary.completedSetCount) SET\(summary.completedSetCount == 1 ? "" : "S")")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkMuted)
                    // Provenance, said rather than implied. Five years of
                    // another app's log shouldn't read as though it was
                    // tracked here.
                    if summary.source != nil {
                        Chip(text: "imported", color: Theme.inkFaint)
                    }
                }
            }
        }
    }

    /// The workout's own title where it has one, otherwise what was in it.
    private var title: String {
        if let notes = summary.notes, !notes.isEmpty { return notes }
        return contents ?? "Empty workout"
    }

    /// The first few lifts, and a count of the rest. `nil` for an empty workout.
    private var contents: String? {
        let names = summary.exerciseNames
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) +\(names.count - 3)" : shown
    }

    private var dateText: String {
        guard let start = summary.startTime else { return "UNKNOWN DATE" }
        // Time of day included — `notes/Feedback.md` asks for it, and with 840
        // sessions "Tue Mar 10" alone stops being enough to tell two apart.
        return start
            .formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())
            .uppercased()
    }

    private var durationText: String? {
        guard let duration = summary.duration, duration > 0 else { return nil }
        let minutes = Int(duration / 60)
        return minutes >= 60 ? "\(minutes / 60)H \(minutes % 60)M" : "\(minutes)M"
    }
}

#Preview {
    WorkoutHistoryView()
        .environment(AppEnvironment.preview())
}

import SwiftUI
import LiftingCoachModel

/// Every logged workout, newest first.
///
/// Deliberately minimal — a flat scrollable list, no calendar, no editing.
/// `Features/Workout History.md` specifies a calendar with day-summary and edit
/// overlays, but that's a low-priority screen and other parts of the app are
/// still likely to change shape underneath it, so this isn't worth building out
/// twice. Upgrade in place when the rest of the app settles.
struct WorkoutHistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var workouts: [Workout] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Panel(accent: Theme.alert.opacity(0.5)) {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.alert)
                    }
                    .panelRow()
                } else if workouts.isEmpty {
                    Panel {
                        Text("No workouts logged yet.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .panelRow()
                } else {
                    ForEach(workouts) { workout in
                        WorkoutHistoryRow(workout: workout)
                            .panelRow()
                    }
                }
            }
            .listStyle(.plain)
            .screenGround()
            .navigationTitle("History")
            .refreshable { load() }
            .task { load() }
        }
    }

    private func load() {
        guard let user = environment.currentUser else { return }
        do {
            // A wide but bounded window rather than "everything ever" — this is
            // a flat unpaginated list, so bound the query until it needs
            // grouping or paging.
            let start = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? .distantPast
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            workouts = try environment.workouts
                .fetch(from: start, to: end)
                .filter { $0.endTime != nil }  // history is finished workouts, not the in-progress one
                .sorted { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
            loadError = nil
            _ = user
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct WorkoutHistoryRow: View {
    let workout: Workout

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 7) {
                Text(dateText)
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.signal)
                Text(exerciseSummary)
                    .font(Theme.heading)
                    .foregroundStyle(Theme.ink)
                Text("\(completedSetCount) SET\(completedSetCount == 1 ? "" : "S")")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private var dateText: String {
        guard let start = workout.startTime else { return "UNKNOWN DATE" }
        return start.formatted(.dateTime.weekday(.abbreviated).month().day().year()).uppercased()
    }

    private var exerciseSummary: String {
        let names = (workout.exercises ?? []).flatMap { $0 }.map(\.exercise.name)
        return names.isEmpty ? "Empty workout" : names.joined(separator: ", ")
    }

    private var completedSetCount: Int {
        workout.allSets.filter { $0.complete == true }.count
    }
}

#Preview {
    WorkoutHistoryView()
        .environment(AppEnvironment.preview())
}

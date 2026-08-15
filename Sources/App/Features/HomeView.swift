import SwiftUI
import LiftingCoachModel

/// Quick actions plus the headline metrics, per `Features/Homepage.md`.
///
/// Only the scaffold-verification parts are live right now: the catalog row
/// proves the SQLite layer is actually wired through `AppEnvironment`, and the
/// block section exercises the real `WorkoutPlan` derivation. The metric tiles
/// (1RM estimates, bodyweight, adherence) are placeholders until there's a
/// persisted `User` and a workout store to read them from.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment

    /// No plan is persisted yet — this is an empty plan so the derivation runs
    /// against the same code path it will in production.
    private let plan = WorkoutPlan()

    @State private var catalogCount: Int?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                currentBlockSection
                metricsSection
                scaffoldSection
            }
            .navigationTitle("Lifting Coach")
            .task(loadCatalogCount)
        }
    }

    @ViewBuilder
    private var currentBlockSection: some View {
        Section("Current Block") {
            if let block = plan.currentBlock(), let progress = block.progress() {
                LabeledContent("Week") {
                    if let total = progress.totalWeeks {
                        Text("\(progress.weekIndex) of \(total)")
                    } else {
                        Text("\(progress.weekIndex)")
                    }
                }
                LabeledContent("Day", value: "\(progress.dayIndex)")
            } else {
                Text("No training block scheduled.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metricsSection: some View {
        Section("Metrics") {
            // Homepage.md: bench, squat, deadlift, bodyweight to start.
            ForEach(["Bench Press", "Back Squat", "Deadlift", "Bodyweight"], id: \.self) { metric in
                LabeledContent(metric, value: "—")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var scaffoldSection: some View {
        Section("Scaffold") {
            LabeledContent("Exercise catalog") {
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                } else if let catalogCount {
                    Text("\(catalogCount) exercises")
                } else {
                    ProgressView()
                }
            }
            LabeledContent("Backend") {
                Text(environment.backend.isAvailable ? "Connected" : "Phase 2")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @Sendable
    private func loadCatalogCount() async {
        do {
            catalogCount = try environment.exercises.fetchAll().count
        } catch {
            loadError = error.localizedDescription
        }
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment.preview())
}

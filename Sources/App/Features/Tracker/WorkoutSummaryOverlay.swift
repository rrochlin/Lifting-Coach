import SwiftUI
import LiftingCoachModel

/// What just happened, shown once when a workout ends.
///
/// **Why finishing needed anything at all.** It used to end in silence: the
/// confirm dialog closed, the session vanished, and the screen fell back to the
/// week view. An hour of work ended with less acknowledgement than deleting a
/// set gets — reported simply as "workout complete pop up after finishing a
/// workout".
///
/// **It reports, it doesn't grade.** Sets, exercises, volume and elapsed time,
/// all counted from the workout as it was actually written to the log. There's
/// no score, no streak and no comparison to the plan: adherence is Home's
/// readout and it's a number the lifter reads, not a verdict the app hands down
/// at the end of a session (Core Tenets §1).
///
/// An overlay rather than a sheet, matching `themedConfirm` — it's about the
/// workout behind it, and a sheet would put a drag-to-dismiss affordance on
/// something with exactly one way out.
struct WorkoutSummaryOverlay: View {
    let workout: Workout
    let unit: WeightUnit
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.void.opacity(0.72)
                .ignoresSafeArea()
                // Tapping outside dismisses too. Nothing here is destructive
                // and nothing is unsaved — the workout is already in the log.
                .onTapGesture(perform: onDismiss)

            Panel(accent: Theme.signal.opacity(0.55)) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    readouts
                    if !names.isEmpty {
                        Text(names.joined(separator: " · "))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(3)
                    }
                    doneButton
                }
            }
            .frame(maxWidth: 340)
            .padding(24)
        }
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.signal)
            Text("WORKOUT COMPLETE")
                .font(Theme.label)
                .tracking(1.6)
                .foregroundStyle(Theme.signal)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let elapsed {
                Readout(label: "time", value: elapsed, accent: Theme.ink, size: 19)
            }
            Readout(label: "sets", value: "\(sets.count)", accent: Theme.ink, size: 19)
            Readout(label: "lifts", value: "\(names.count)", accent: Theme.inkMuted, size: 15)
            if let volume {
                Readout(label: "volume", value: volume, accent: Theme.inkMuted, size: 15)
            }
        }
    }

    private var doneButton: some View {
        Button(action: onDismiss) {
            Text("DONE")
                .font(Theme.label)
                .tracking(1.6)
                .foregroundStyle(Theme.signal)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.signal.opacity(0.55), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Numbers

    /// `finish` has already dropped incomplete sets, so everything here is work
    /// that actually happened.
    private var sets: [WorkoutSet] { workout.allSets }

    private var names: [String] {
        (workout.exercises ?? []).flatMap { $0 }.map(\.displayName)
    }

    private var elapsed: String? {
        guard let start = workout.startTime, let end = workout.endTime else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Reps × weight, summed. **Working sets only** — a warmup ramp is real
    /// work but it isn't the session's tonnage, and including it would make the
    /// number move for a reason the lifter didn't choose. Summed in the lifter's
    /// own unit so mixed-unit sets don't add pounds to kilograms.
    private var volume: String? {
        let total = sets
            .filter { ($0.type ?? .working) == .working }
            .compactMap { set -> Double? in
                guard let reps = set.reps, let weight = set.weight else { return nil }
                return Double(reps) * weight.converted(to: unit.unit).value
            }
            .reduce(0, +)
        guard total > 0 else { return nil }
        return "\(Int(total.rounded())) \(unit.symbol)"
    }
}

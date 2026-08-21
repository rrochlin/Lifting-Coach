import SwiftUI
import LiftingCoachModel

/// "✓ 12 / 13 SETS LOGGED" — that this day was trained, and how much of it
/// landed.
///
/// **A count rather than a verdict.** The join between a logged session and a
/// programmed day is by date (see `BlockCompletion`), so the app is not in a
/// position to declare a day "done" — a session cut short after two of five
/// exercises would wear the same badge as a full one. Showing logged sets
/// against programmed sets puts the fact on screen and leaves the reading to
/// the lifter (Core Tenets §1). It's the same choice Home's adherence readout
/// makes, and the same numbers.
///
/// **At the foot of the panel, not in its header.** As a chip beside the date
/// it took ~110pt off the one flexible element on that row, and the program's
/// own day labels put their content last ("Week 1 Mon - Bench+Squat"), so a
/// trained day truncated to "Week 1 M…" — the marker was eating exactly the
/// words that say what the day *is*. Down here it has the panel's full width,
/// which is also why it can spell out what it's counting. Reading order comes
/// out right too: what was prescribed, then what happened.
///
/// Cyan with a glyph, because done-ness must not be colour alone (WCAG §1.4.1)
/// and cyan already means complete everywhere else — a finished rest period, a
/// completed set.
struct TrainedMarker: View {
    let log: BlockCompletion.DayLog

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text(text)
                    .font(Theme.label)
                    .tracking(1.4)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.signal)
        }
        .padding(.top, 2)
    }

    /// A day with nothing prescribed still logged real sets — a recovery walk,
    /// an ad-hoc session — and "14 / 0" would be nonsense, so the ratio drops
    /// and the count stays.
    private var text: String {
        let sets = log.plannedSets > 0
            ? "\(log.loggedSets) / \(log.plannedSets) SETS LOGGED"
            : "\(log.loggedSets) SETS LOGGED"
        // Two sessions on one day is rare and worth saying, since the count
        // beside it is their total rather than any one session's.
        return log.sessions > 1 ? "\(log.sessions) SESSIONS · \(sets)" : sets
    }
}

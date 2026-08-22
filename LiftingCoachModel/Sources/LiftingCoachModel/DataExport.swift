import Foundation

/// Everything the app holds about one lifter, in one file.
///
/// `Features/User Profile.md` asks for export, and `Design.md`'s "never destroy
/// historical data" is the reason it matters more here than in most apps: five
/// years of training log lives on one phone, in one SQLite file, with no server
/// behind it until phase 2. Export is the only thing standing between a lost
/// phone and a lost career of data.
///
/// **It's an archive, not a report.** The shape is the domain model, encoded —
/// not a flattened summary — so it round-trips: what comes out is what the app
/// would need to put it back. That's also why nothing is dropped for being
/// redundant. `plannedFrom` snapshots, `source` tags, per-set units and the
/// prescriptions on the plan side are all here, because an archive that quietly
/// omits a field is one that silently loses it.
///
/// **`formatVersion` is the only forward compatibility promise made.** Reading
/// an archive is not built (there's no import UI in phase 1, by direction — see
/// `Roadmap.md`), so this exists to make a future reader able to tell what it's
/// looking at rather than guessing from shape.
public struct DataExport: Codable, Sendable {
    /// Bumped when the shape changes incompatibly. Additive fields don't.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// The app that wrote it, for an archive that outlives this version.
    public var app: String
    public var exportedAt: Date
    /// The lifter, carrying maxes, bodyweight history and unit preferences.
    public var user: User
    /// Every logged workout, oldest first, fully hydrated.
    public var workouts: [Workout]
    /// The programming: blocks with their planned days.
    public var plan: WorkoutPlan
    /// Counts, so the file states what it contains without being parsed. The
    /// same numbers the export screen reports, from the same place, so the two
    /// cannot disagree.
    public var counts: Counts

    public struct Counts: Codable, Hashable, Sendable {
        public var workouts: Int
        public var sets: Int
        public var blocks: Int
        public var plannedWorkouts: Int

        public init(workouts: Int, sets: Int, blocks: Int, plannedWorkouts: Int) {
            self.workouts = workouts
            self.sets = sets
            self.blocks = blocks
            self.plannedWorkouts = plannedWorkouts
        }
    }

    public init(
        formatVersion: Int = DataExport.currentFormatVersion,
        app: String = "Lifting-Coach",
        exportedAt: Date = Date(),
        user: User,
        workouts: [Workout],
        plan: WorkoutPlan
    ) {
        self.formatVersion = formatVersion
        self.app = app
        self.exportedAt = exportedAt
        self.user = user
        self.workouts = workouts
        self.plan = plan
        self.counts = Counts(
            workouts: workouts.count,
            sets: workouts.reduce(0) { $0 + $1.allSets.count },
            blocks: (plan.blocks ?? []).count,
            plannedWorkouts: (plan.blocks ?? []).reduce(0) { total, block in
                total + (block.program ?? [:]).values.reduce(0) { $0 + $1.count }
            }
        )
    }

    /// A filename that sorts chronologically and says what it is.
    public func suggestedFilename(calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return "lifting-coach-\(formatter.string(from: exportedAt)).json"
    }
}

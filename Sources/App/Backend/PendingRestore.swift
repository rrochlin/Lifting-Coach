import Foundation
import LiftingCoachPersistence

/// A cloud backup downloaded and waiting to replace the database at the next
/// launch.
///
/// **Why next launch and not now.** `SnapshotImporter.install` swaps the
/// database file, which is only safe with no connection open — and by the time
/// the lifter is on Profile choosing to restore, every store in
/// `AppEnvironment` holds one. Rebuilding the whole environment in place would
/// mean every view letting go of every store mid-flight. Applying the restore
/// before anything opens the database is simple and can't half-happen, and the
/// screen says plainly that it takes effect when the app is next opened.
///
/// **Checked twice.** Once when staged, so a restore that would discard
/// workouts on this phone is refused while the lifter is looking at it; and
/// again by `install` at launch, because a workout can be logged between
/// choosing to restore and reopening the app — and a restore that silently
/// replaced *that* would be the worst version of this feature.
struct PendingRestore: Codable, Equatable {
    /// The account the backup belongs to, so the watermark is written for the
    /// right one.
    var account: String
    /// The version restored. Becomes the precondition for the next upload, so
    /// the first write after a restore replaces exactly what was restored.
    var etag: String

    static func directory(fileManager: FileManager = .default) throws -> URL {
        try AppDatabase.defaultURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("restore", isDirectory: true)
    }

    static func archiveURL() throws -> URL {
        try directory().appendingPathComponent("snapshot.sqlite.gz")
    }

    private static func markerURL() throws -> URL {
        try directory().appendingPathComponent("pending.json")
    }

    static func pending() -> PendingRestore? {
        guard let url = try? markerURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingRestore.self, from: data)
    }

    func stage() throws {
        try JSONEncoder().encode(self).write(to: Self.markerURL(), options: .atomic)
    }

    static func discard() {
        guard let directory = try? directory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// What happened at launch, for Profile to report once.
    enum Outcome: Equatable {
        case restored(workouts: Int)
        case refused(String)
    }

    /// Runs before the database is opened. Never throws: a restore that can't
    /// be applied leaves the device exactly as it was and says why.
    static func applyIfStaged(watermarks: any SnapshotWatermarkStore) -> Outcome? {
        guard let pending = pending() else { return nil }
        defer { discard() }
        do {
            let archive = try archiveURL()
            let databaseURL = try AppDatabase.defaultURL()
            let importer = SnapshotImporter()
            let prepared = try importer.prepare(archive, into: try directory(), named: "incoming")
            defer { try? FileManager.default.removeItem(at: prepared.url) }
            try importer.install(prepared, replacing: databaseURL)
            // The device now holds the cloud version it names, without having
            // exported it — so no digest, and the etag as the next precondition.
            watermarks.setWatermark(nil, etag: pending.etag, for: pending.account)
            return .restored(workouts: prepared.rowCounts["workout"] ?? 0)
        } catch SnapshotImportError.wouldDiscardLocalWorkouts(let count) {
            return .refused("Not restored: \(count) workout\(count == 1 ? "" : "s") logged on this phone since you chose to restore aren't in the backup, and restoring would delete them.")
        } catch {
            return .refused("Not restored: \(error.localizedDescription)")
        }
    }
}

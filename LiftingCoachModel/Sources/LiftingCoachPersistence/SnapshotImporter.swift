import Foundation
import GRDB

/// Installs a downloaded snapshot over the on-device database.
///
/// **This is the one destructive operation phase 2 adds**, and the only place in
/// the whole design where a server-held file can end a training log. Everything
/// else moves data the other way. That asymmetry is why the refusal below is a
/// precondition of installing rather than a check a caller is expected to run
/// first — Core Tenets §8 says never destroy what was actually lifted, and a
/// rule that only holds when someone remembers it is not that guarantee.
///
/// The intended use is sign-in on a fresh install: the local database has
/// nothing in it, so restoring loses nothing. Any other case has to be refused,
/// because there is no merge to fall back on — the whole design turns on there
/// being exactly one writer, so two divergent copies of a log are a state this
/// system has no way to reconcile and shouldn't pretend to.
///
/// It works on **file paths, not on a live `AppDatabase`**. Replacing the file
/// under an open `DatabasePool` would leave a connection reading pages that no
/// longer mean anything, so the caller closes the database first, calls
/// `install`, and opens a new one.
public struct SnapshotImporter: Sendable {
    public init() {}

    /// A snapshot unpacked and checked, ready to be installed or refused.
    public struct Prepared: Sendable, Equatable {
        /// The decompressed SQLite file. The caller owns it, including deleting
        /// it — it is an unencrypted copy of a training log.
        public let url: URL
        public let schemaVersion: String
        public let rowCounts: [String: Int]

        public init(url: URL, schemaVersion: String, rowCounts: [String: Int]) {
            self.url = url
            self.schemaVersion = schemaVersion
            self.rowCounts = rowCounts
        }
    }

    /// What restoring would cost, for a screen to show before anyone taps.
    public struct Assessment: Sendable, Equatable {
        /// Workouts on this device the snapshot doesn't have. Any at all means
        /// the restore is refused: these are sessions that were lifted, and
        /// they would simply stop existing.
        public let localOnlyCount: Int
        /// The days those sessions fall on, for saying which ones out loud
        /// rather than only how many. Shorter than `localOnlyCount` if a
        /// workout carries no date, which is why the count is separate.
        public let localOnlyDays: [Date]
        /// Workouts in the snapshot this device doesn't have — the normal case
        /// on a fresh install, and the reason to restore at all.
        public let snapshotOnlyCount: Int

        public var isSafe: Bool { localOnlyCount == 0 }

        public init(localOnlyCount: Int, localOnlyDays: [Date], snapshotOnlyCount: Int) {
            self.localOnlyCount = localOnlyCount
            self.localOnlyDays = localOnlyDays
            self.snapshotOnlyCount = snapshotOnlyCount
        }
    }

    /// Decompresses `archive` into `directory` and reads what it is.
    ///
    /// Refuses a schema this build doesn't know: a snapshot written by a newer
    /// app cannot be migrated backwards, and installing it would leave the app
    /// reading columns it has no code for.
    public func prepare(
        _ archive: URL,
        into directory: URL,
        named name: String = "restore",
        fileManager: FileManager = .default
    ) throws -> Prepared {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let unpacked = directory.appendingPathComponent("\(name).sqlite")
        try? fileManager.removeItem(at: unpacked)
        try Gzip.decompress(fileAt: archive, to: unpacked)

        var config = Configuration()
        config.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: unpacked.path, configuration: config)
        } catch {
            throw SnapshotImportError.notALiftingCoachDatabase
        }

        return try queue.read { db in
            guard try db.tableExists("grdb_migrations"), try db.tableExists("workout") else {
                throw SnapshotImportError.notALiftingCoachDatabase
            }
            let applied = try AppDatabase.migrator.appliedIdentifiers(db)
            let known = Set(AppDatabase.migrator.migrations)
            if let unknown = applied.subtracting(known).sorted().first {
                throw SnapshotImportError.snapshotIsNewerThanApp(unknown)
            }
            guard let version = AppDatabase.migrator.migrations.last(where: applied.contains) else {
                throw SnapshotImportError.notALiftingCoachDatabase
            }

            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
            var counts: [String: Int] = [:]
            for table in tables {
                let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quoted)") ?? 0
            }
            return Prepared(url: unpacked, schemaVersion: version, rowCounts: counts)
        }
    }

    /// Compares the snapshot against the database currently on the device.
    ///
    /// Identity is the workout id, which is generated on the device and travels
    /// with the row, so "the snapshot has this session" is an exact question
    /// rather than a heuristic over dates and names.
    ///
    /// A device with no database at all assesses as safe — that is the fresh
    /// install this exists for.
    public func assess(
        _ prepared: Prepared,
        against databaseURL: URL,
        fileManager: FileManager = .default
    ) throws -> Assessment {
        let incoming = try workouts(in: prepared.url)

        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return Assessment(
                localOnlyCount: 0,
                localOnlyDays: [],
                snapshotOnlyCount: incoming.count
            )
        }

        let local: [(id: DatabaseValue, day: Date?)]
        do {
            local = try workouts(in: databaseURL)
        } catch {
            // Something is there and it isn't readable. That is not the same as
            // "nothing is there": we cannot account for what it holds, so we
            // don't get to decide it holds nothing. `install` can be told to
            // replace it anyway, which makes discarding it a decision someone
            // takes rather than a default that happens quietly.
            throw SnapshotImportError.deviceDatabaseUnreadable
        }

        let incomingIDs = Set(incoming.map(\.id))
        let localIDs = Set(local.map(\.id))
        let localOnly = local.filter { !incomingIDs.contains($0.id) }

        return Assessment(
            localOnlyCount: localOnly.count,
            localOnlyDays: localOnly.compactMap(\.day).sorted(),
            snapshotOnlyCount: incoming.filter { !localIDs.contains($0.id) }.count
        )
    }

    /// Replaces the database at `databaseURL` with the snapshot.
    ///
    /// Re-runs `assess` itself and throws rather than trusting the caller to
    /// have looked. The check is cheap and the failure is permanent.
    ///
    /// `replacingUnreadableDatabase` covers exactly one case: the file on the
    /// device won't open at all, so nothing can say what it holds. That is a
    /// decision for the lifter — otherwise a corrupt database would be the one
    /// state a restore could never repair — and it is deliberately *only* that
    /// case. A database that opens and holds sessions the snapshot lacks is
    /// refused no matter what this is set to; that guarantee has no override.
    ///
    /// The database must be closed. The `-wal` and `-shm` sidecars of the old
    /// database are deleted along with it: a stale WAL beside a completely
    /// different main file is not merely useless, SQLite may try to replay it.
    public func install(
        _ prepared: Prepared,
        replacing databaseURL: URL,
        replacingUnreadableDatabase: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        do {
            let assessment = try assess(prepared, against: databaseURL, fileManager: fileManager)
            guard assessment.isSafe else {
                throw SnapshotImportError.wouldDiscardLocalWorkouts(count: assessment.localOnlyCount)
            }
        } catch SnapshotImportError.deviceDatabaseUnreadable where replacingUnreadableDatabase {
            // Asked for explicitly, so proceed.
        }

        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for suffix in ["", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            try? fileManager.removeItem(at: sidecar)
        }
        try fileManager.moveItem(at: prepared.url, to: databaseURL)
    }

    /// Ids come back as raw `DatabaseValue` rather than decoded `UUID`s.
    ///
    /// This only ever does set arithmetic on them, and comparing the stored
    /// values directly means the comparison can't be wrong about how GRDB
    /// happens to encode a `UUID` — which is a detail of the mapping layer, not
    /// something the safety check should depend on.
    private func workouts(in database: URL) throws -> [(id: DatabaseValue, day: Date?)] {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: database.path, configuration: config)
        return try queue.read { db in
            guard try db.tableExists("workout") else { return [] }
            let rows = try Row.fetchAll(db, sql: "SELECT id, COALESCE(day, startTime) AS day FROM workout")
            return rows.map { (id: $0["id"], day: $0["day"]) }
        }
    }
}

public enum SnapshotImportError: Error, Equatable {
    /// The device holds sessions the snapshot doesn't. There is no merge, so
    /// this is refused outright (Core Tenets §8).
    case wouldDiscardLocalWorkouts(count: Int)
    /// Written by a newer build; the named migration is one this app has never
    /// heard of. Migrations only run forwards.
    case snapshotIsNewerThanApp(String)
    case notALiftingCoachDatabase
    /// There is a file where the database should be and it won't open. What it
    /// holds is unknowable, so replacing it is a decision rather than a default
    /// — see `install(_:replacing:replacingUnreadableDatabase:)`.
    case deviceDatabaseUnreadable
}

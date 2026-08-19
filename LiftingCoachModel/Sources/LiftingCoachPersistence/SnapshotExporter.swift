import Foundation
import GRDB

/// Exports the on-device database as one compressed file, for upload to S3.
///
/// This is the whole of the phone's half of phase 2's storage design (see
/// `notes/Workout App/Backend/Overview.md`): the phone stays the system of
/// record and the server gets a read-only copy. Nothing here uploads anything —
/// that's `BackendClient`'s job — and nothing on the server ever writes back
/// into what this produces. A coach's output is a draft program, not an edit.
///
/// Three properties this deliberately has:
///
/// - **It exports with `VACUUM INTO`, never a file copy.** A live SQLite
///   database in WAL mode is a set of files with in-flight state; copying
///   `db.sqlite` alone can capture a torn read, and copying it with its sidecars
///   makes the "snapshot" three objects. `VACUUM INTO` writes one consistent,
///   compacted file from a single point in time.
/// - **The gzip is a real gzip container**, not Apple's raw DEFLATE stream. The
///   thing reading this is a Python Lambda, and `gzip.open` and `gunzip` both
///   have to work on it or every debugging session starts with a decoder. The
///   header carries no mtime, so identical data compresses to identical bytes
///   and the S3 ETag means what it appears to mean.
/// - **The description is read back out of the exported file**, not off the live
///   database. The stamp has to describe the bytes being uploaded; reading the
///   source would let the two disagree in exactly the case that matters.
public struct SnapshotExporter: Sendable {
    /// One exported file, plus what the server needs to decide whether to
    /// accept it. `schemaVersion` and `rowCounts` are what `snapshotMeta`
    /// records in DynamoDB.
    public struct Snapshot: Sendable, Equatable {
        /// The gzipped file on disk. The caller owns it, including deleting it.
        public let url: URL
        /// Compressed size, which is what actually gets PUT.
        public let byteCount: Int
        /// SHA-256 of the compressed bytes, lowercase hex — what the receiver
        /// checks the upload against.
        public let sha256: String
        /// The last applied migration identifier, e.g. `v13_setDurationDistance`.
        /// The server refuses a version it doesn't know, the same discipline
        /// `liftimport` applies in the other direction.
        public let schemaVersion: String
        /// Row count per user table, name-keyed. Cheap, and it makes "the
        /// upload succeeded but the file is wrong" a detectable state.
        public let rowCounts: [String: Int]
        public let createdAt: Date

        public init(
            url: URL,
            byteCount: Int,
            sha256: String,
            schemaVersion: String,
            rowCounts: [String: Int],
            createdAt: Date
        ) {
            self.url = url
            self.byteCount = byteCount
            self.sha256 = sha256
            self.schemaVersion = schemaVersion
            self.rowCounts = rowCounts
            self.createdAt = createdAt
        }
    }

    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    /// Writes `<name>.sqlite.gz` into `directory` and describes it.
    ///
    /// The uncompressed intermediate is an unencrypted copy of the lifter's
    /// training log, so it lives exactly as long as it takes to compress it.
    @discardableResult
    public func export(
        to directory: URL,
        named name: String = "snapshot",
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> Snapshot {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let plain = directory.appendingPathComponent("\(name).sqlite")
        let compressed = directory.appendingPathComponent("\(name).sqlite.gz")

        // VACUUM INTO refuses to overwrite, so a leftover from a previous run
        // would fail every export from here on.
        try? fileManager.removeItem(at: plain)
        try? fileManager.removeItem(at: compressed)
        defer { try? fileManager.removeItem(at: plain) }

        // VACUUM cannot run inside a transaction, which is what `write` would
        // open. The path is bound rather than interpolated — SQLite takes an
        // expression here, so quoting is not our problem.
        try database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [plain.path])
        }

        let described = try Self.describe(plain)
        let output = try Gzip.compress(fileAt: plain, to: compressed)

        return Snapshot(
            url: compressed,
            byteCount: output.byteCount,
            sha256: output.sha256,
            schemaVersion: described.schemaVersion,
            rowCounts: described.rowCounts,
            createdAt: now
        )
    }

    /// Opens the exported file read-only and reads what it is.
    ///
    /// Read-only matters beyond hygiene: opening it through `AppDatabase` would
    /// run the migrator, so a snapshot could quietly be *upgraded* on its way
    /// out and stamped with a version it wasn't written at.
    private static func describe(
        _ url: URL
    ) throws -> (schemaVersion: String, rowCounts: [String: Int]) {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)

        return try queue.read { db in
            // `grdb_migrations` is an unordered set of identifiers, so "the
            // last one" only exists relative to the registration order.
            let applied = try AppDatabase.migrator.appliedIdentifiers(db)
            guard let version = AppDatabase.migrator.migrations.last(where: applied.contains) else {
                throw SnapshotExportError.noAppliedMigrations
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
            return (version, counts)
        }
    }
}

public enum SnapshotExportError: Error, Equatable {
    /// The exported file carries no migration this build knows about. Either
    /// it isn't our database, or it was written by a future version.
    case noAppliedMigrations
}

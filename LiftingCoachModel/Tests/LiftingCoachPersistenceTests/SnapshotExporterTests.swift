import CryptoKit
import Foundation
import Testing
import GRDB
import LiftingCoachModel
@testable import LiftingCoachPersistence

/// A scratch directory that cleans up after itself.
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

/// A database on disk, because that's what actually gets exported. An in-memory
/// one would `VACUUM INTO` fine and prove nothing about the WAL sidecars this
/// design exists to avoid uploading.
private func makeDatabase(in directory: URL) throws -> AppDatabase {
    try AppDatabase.onDisk(at: directory.appendingPathComponent("db.sqlite"))
}

private func finished(_ exercise: Exercise, on date: Date) -> Workout {
    Workout(
        exercises: [[WorkoutExercise(
            exercise: exercise,
            sets: [WorkoutSet(
                reps: 5,
                weight: Measurement(value: 225, unit: .pounds),
                complete: true,
                type: .working
            )]
        )]],
        startTime: date,
        endTime: date.addingTimeInterval(3600)
    )
}

/// Decompresses with the system `gunzip`, which is the point of the assertion:
/// the container has to be a real gzip, because the thing that reads it in
/// production is a Python Lambda and not this code.
private func gunzip(_ url: URL, to destination: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
    process.arguments = ["-c", url.path]
    let output = FileManager.default.createFile(atPath: destination.path, contents: nil)
    #expect(output)
    process.standardOutput = try FileHandle(forWritingTo: destination)
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let message = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "gunzip failed: \(message)")
}

private func rowCounts(of database: URL) throws -> [String: Int] {
    var config = Configuration()
    config.readonly = true
    let queue = try DatabaseQueue(path: database.path, configuration: config)
    return try queue.read { db in
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """)
        var counts: [String: Int] = [:]
        for table in tables {
            counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
        }
        return counts
    }
}

@Suite("SnapshotExporter")
struct SnapshotExporterTests {
    /// The whole contract in one test: what comes back out of the file the
    /// server would receive is the database that went in.
    @Test func roundTripsThroughGunzipWithTheSameRows() throws {
        try withTemporaryDirectory { directory in
            let database = try makeDatabase(in: directory)
            let exercises = ExerciseStore(database)
            try exercises.save(ExerciseCatalog.seed)
            try WorkoutStore(database).save(
                finished(ExerciseCatalog.seed[0], on: Date(timeIntervalSince1970: 1_700_000_000))
            )

            let out = directory.appendingPathComponent("out", isDirectory: true)
            let snapshot = try SnapshotExporter(database).export(to: out)

            let restored = out.appendingPathComponent("restored.sqlite")
            try gunzip(snapshot.url, to: restored)

            #expect(try rowCounts(of: restored) == snapshot.rowCounts)
            #expect(snapshot.rowCounts["workout"] == 1)
            #expect(snapshot.rowCounts["workoutSet"] == 1)
            #expect(snapshot.rowCounts["exercise"] == ExerciseCatalog.seed.count)
        }
    }

    /// The uncompressed intermediate is an unencrypted copy of a training log.
    /// It is not allowed to outlive the export.
    @Test func leavesNoUncompressedCopyBehind() throws {
        try withTemporaryDirectory { directory in
            let database = try makeDatabase(in: directory)
            let out = directory.appendingPathComponent("out", isDirectory: true)
            let snapshot = try SnapshotExporter(database).export(to: out)

            let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
            #expect(files == ["snapshot.sqlite.gz"])
            #expect(FileManager.default.fileExists(atPath: snapshot.url.path))
        }
    }

    @Test func stampsTheLastAppliedMigration() throws {
        try withTemporaryDirectory { directory in
            let database = try makeDatabase(in: directory)
            let snapshot = try SnapshotExporter(database)
                .export(to: directory.appendingPathComponent("out"))
            #expect(snapshot.schemaVersion == AppDatabase.migrator.migrations.last)
        }
    }

    @Test func checksumAndSizeDescribeTheFileOnDisk() throws {
        try withTemporaryDirectory { directory in
            let database = try makeDatabase(in: directory)
            let snapshot = try SnapshotExporter(database)
                .export(to: directory.appendingPathComponent("out"))

            let bytes = try Data(contentsOf: snapshot.url)
            #expect(bytes.count == snapshot.byteCount)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(digest == snapshot.sha256)
        }
    }

    /// Two exports of an unchanged database have to be the same bytes, or every
    /// upload looks like a change and the ETag stops meaning anything. This is
    /// what the zeroed gzip mtime is for.
    @Test func unchangedDataExportsToIdenticalBytes() throws {
        try withTemporaryDirectory { directory in
            let database = try makeDatabase(in: directory)
            try ExerciseStore(database).save(ExerciseCatalog.seed)
            let exporter = SnapshotExporter(database)
            let out = directory.appendingPathComponent("out")

            let first = try exporter.export(to: out, named: "a")
            let second = try exporter.export(to: out, named: "b")

            #expect(first.sha256 == second.sha256)
            #expect(try Data(contentsOf: first.url) == (try Data(contentsOf: second.url)))
        }
    }

    /// `VACUUM INTO` refuses to overwrite, so an export that didn't clear the
    /// previous run would work exactly once per install.
    @Test func exportingTwiceIntoTheSameDirectorySucceeds() throws {
        try withTemporaryDirectory { directory in
            let database = try makeDatabase(in: directory)
            let exporter = SnapshotExporter(database)
            let out = directory.appendingPathComponent("out")

            try exporter.export(to: out)
            try ExerciseStore(database).save(ExerciseCatalog.seed)
            let second = try exporter.export(to: out)

            #expect(second.rowCounts["exercise"] == ExerciseCatalog.seed.count)
        }
    }

    /// A fresh install has nothing logged, and that is a legitimate snapshot —
    /// it still carries the schema version the server checks.
    @Test func exportsAnEmptyDatabase() throws {
        try withTemporaryDirectory { directory in
            let database = try makeDatabase(in: directory)
            let snapshot = try SnapshotExporter(database)
                .export(to: directory.appendingPathComponent("out"))

            #expect(snapshot.rowCounts["workout"] == 0)
            #expect(snapshot.byteCount > 0)
            #expect(snapshot.schemaVersion == AppDatabase.migrator.migrations.last)
        }
    }

    /// The real catalog is ~870 rows and a few megabytes of database, which is
    /// what pushes the encoder through many 64 KB windows. A gzip that only
    /// works below one buffer's worth would pass every other test here.
    @Test func roundTripsTheFullCatalogAcrossManyBuffers() throws {
        try withTemporaryDirectory { directory in
            let database = try makeDatabase(in: directory)
            let imported = try CatalogImporter(database)
                .importCatalog(CatalogImporter.bundledCatalog)
            #expect(imported.importedCount > 500)

            let out = directory.appendingPathComponent("out", isDirectory: true)
            let snapshot = try SnapshotExporter(database).export(to: out)

            let restored = out.appendingPathComponent("restored.sqlite")
            try gunzip(snapshot.url, to: restored)

            let restoredCounts = try rowCounts(of: restored)
            #expect(restoredCounts == snapshot.rowCounts)
            #expect(restoredCounts["exercise"] == imported.importedCount)

            // Uncompressed, this is a multi-megabyte file; if it isn't, the
            // test isn't exercising what it claims to.
            let uncompressed = try Data(contentsOf: restored).count
            #expect(uncompressed > 512 * 1024)
            #expect(snapshot.byteCount < uncompressed)
        }
    }
}

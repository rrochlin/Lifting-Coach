import Foundation
import Testing
import GRDB
import LiftingCoachModel
@testable import LiftingCoachPersistence

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("restore-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

private func workout(on date: Date) -> Workout {
    Workout(
        exercises: [[WorkoutExercise(
            exercise: ExerciseCatalog.seed[0],
            sets: [WorkoutSet(reps: 5, weight: Measurement(value: 225, unit: .pounds), complete: true, type: .working)]
        )]],
        startTime: date,
        endTime: date.addingTimeInterval(3600)
    )
}

private let day0 = Date(timeIntervalSince1970: 1_700_000_000)

/// A database on disk with `count` finished workouts, returned closed-over so a
/// test can keep logging into it.
private func makeDatabase(at url: URL, workouts count: Int) throws -> AppDatabase {
    let database = try AppDatabase.onDisk(at: url)
    try ExerciseStore(database).save(ExerciseCatalog.seed)
    let store = WorkoutStore(database)
    for index in 0..<count {
        try store.save(workout(on: day0.addingTimeInterval(Double(index) * 86_400)))
    }
    return database
}

private func workoutCount(at url: URL) throws -> Int {
    var config = Configuration()
    config.readonly = true
    let queue = try DatabaseQueue(path: url.path, configuration: config)
    return try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workout") ?? -1 }
}

@Suite("SnapshotImporter")
struct SnapshotImporterTests {
    /// The case this exists for: a new phone, nothing logged on it yet.
    @Test func restoresOntoAFreshDevice() throws {
        try withTemporaryDirectory { directory in
            let source = try makeDatabase(at: directory.appendingPathComponent("source.sqlite"), workouts: 3)
            let archive = try SnapshotExporter(source)
                .export(to: directory.appendingPathComponent("out")).url

            let importer = SnapshotImporter()
            let prepared = try importer.prepare(archive, into: directory.appendingPathComponent("work"))
            #expect(prepared.rowCounts["workout"] == 3)
            #expect(prepared.schemaVersion == AppDatabase.migrator.migrations.last)

            let target = directory.appendingPathComponent("device/db.sqlite")
            let assessment = try importer.assess(prepared, against: target)
            #expect(assessment.isSafe)
            #expect(assessment.snapshotOnlyCount == 3)

            try importer.install(prepared, replacing: target)
            #expect(try workoutCount(at: target) == 3)

            // And it opens as a real database this build can migrate and use.
            let restored = try AppDatabase.onDisk(at: target)
            let names = try restored.writer.read {
                try String.fetchAll($0, sql: "SELECT name FROM exercise ORDER BY name LIMIT 1")
            }
            #expect(!names.isEmpty)
        }
    }

    /// Core Tenets §8. There is no merge to fall back on, so a session logged
    /// here and missing from the backup makes the restore illegal, not lossy.
    @Test func refusesWhenTheDeviceHasWorkoutsTheSnapshotLacks() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("device.sqlite")
            let device = try makeDatabase(at: target, workouts: 2)
            let archive = try SnapshotExporter(device)
                .export(to: directory.appendingPathComponent("out")).url

            // The lifter then trains in a basement gym, and nothing uploads.
            let unbackedUp = day0.addingTimeInterval(99 * 86_400)
            try WorkoutStore(device).save(workout(on: unbackedUp))

            let importer = SnapshotImporter()
            let prepared = try importer.prepare(archive, into: directory.appendingPathComponent("work"))

            let assessment = try importer.assess(prepared, against: target)
            #expect(!assessment.isSafe)
            #expect(assessment.localOnlyCount == 1)
            #expect(assessment.snapshotOnlyCount == 0)
            // Named, not just counted, so a screen can say which session.
            #expect(assessment.localOnlyDays.count == 1)

            #expect(throws: SnapshotImportError.wouldDiscardLocalWorkouts(count: 1)) {
                try importer.install(prepared, replacing: target)
            }
            // And the refusal left the device exactly as it was.
            #expect(try workoutCount(at: target) == 3)
        }
    }

    /// The same device that made the snapshot, restoring it back: every local
    /// workout is in the file, so nothing is lost and it's allowed.
    @Test func allowsRestoringASnapshotTheDeviceItselfProduced() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("device.sqlite")
            let device = try makeDatabase(at: target, workouts: 4)
            let archive = try SnapshotExporter(device)
                .export(to: directory.appendingPathComponent("out")).url

            let importer = SnapshotImporter()
            let prepared = try importer.prepare(archive, into: directory.appendingPathComponent("work"))
            let assessment = try importer.assess(prepared, against: target)

            #expect(assessment.isSafe)
            #expect(assessment.localOnlyCount == 0)
            #expect(assessment.snapshotOnlyCount == 0)

            try importer.install(prepared, replacing: target)
            #expect(try workoutCount(at: target) == 4)
        }
    }

    /// A WAL left beside the old database describes pages of a file that no
    /// longer exists. SQLite may try to replay it.
    @Test func clearsTheOldDatabasesSidecars() throws {
        try withTemporaryDirectory { directory in
            let source = try makeDatabase(at: directory.appendingPathComponent("source.sqlite"), workouts: 1)
            let archive = try SnapshotExporter(source)
                .export(to: directory.appendingPathComponent("out")).url

            let target = directory.appendingPathComponent("device.sqlite")
            let device = try makeDatabase(at: target, workouts: 0)
            // A WAL and an SHM the way a live database leaves them.
            try device.writer.write { _ in }
            #expect(FileManager.default.fileExists(atPath: target.path + "-wal"))

            let importer = SnapshotImporter()
            let prepared = try importer.prepare(archive, into: directory.appendingPathComponent("work"))
            try importer.install(prepared, replacing: target)

            #expect(!FileManager.default.fileExists(atPath: target.path + "-wal"))
            #expect(!FileManager.default.fileExists(atPath: target.path + "-shm"))
            #expect(try workoutCount(at: target) == 1)
        }
    }

    /// A file that won't open holds an unknown number of sessions, and "unknown"
    /// is not "none". Replacing it is available, but only when asked for.
    @Test func refusesAnUnreadableDeviceDatabaseUnlessTold() throws {
        try withTemporaryDirectory { directory in
            let source = try makeDatabase(at: directory.appendingPathComponent("source.sqlite"), workouts: 1)
            let archive = try SnapshotExporter(source)
                .export(to: directory.appendingPathComponent("out")).url

            let target = directory.appendingPathComponent("device.sqlite")
            try Data("not really a database".utf8).write(to: target)

            let importer = SnapshotImporter()
            let prepared = try importer.prepare(archive, into: directory.appendingPathComponent("work"))

            #expect(throws: SnapshotImportError.deviceDatabaseUnreadable) {
                try importer.assess(prepared, against: target)
            }
            #expect(throws: SnapshotImportError.deviceDatabaseUnreadable) {
                try importer.install(prepared, replacing: target)
            }

            try importer.install(prepared, replacing: target, replacingUnreadableDatabase: true)
            #expect(try workoutCount(at: target) == 1)
        }
    }

    /// The override covers unreadable files and nothing else — a readable
    /// database holding sessions the snapshot lacks is refused either way.
    @Test func theOverrideCannotDiscardReadableWorkouts() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("device.sqlite")
            let device = try makeDatabase(at: target, workouts: 1)
            let archive = try SnapshotExporter(device)
                .export(to: directory.appendingPathComponent("out")).url
            try WorkoutStore(device).save(workout(on: day0.addingTimeInterval(99 * 86_400)))

            let importer = SnapshotImporter()
            let prepared = try importer.prepare(archive, into: directory.appendingPathComponent("work"))

            #expect(throws: SnapshotImportError.wouldDiscardLocalWorkouts(count: 1)) {
                try importer.install(prepared, replacing: target, replacingUnreadableDatabase: true)
            }
            #expect(try workoutCount(at: target) == 2)
        }
    }

    /// Migrations only run forwards, so a snapshot written by a newer build
    /// can't be installed — better a clear refusal than an app reading columns
    /// it has no code for.
    @Test func refusesASnapshotFromANewerBuild() throws {
        try withTemporaryDirectory { directory in
            let database = try AppDatabase.onDisk(at: directory.appendingPathComponent("future.sqlite"))
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99_from_the_future')")
            }
            let archive = try SnapshotExporter(database)
                .export(to: directory.appendingPathComponent("out")).url

            #expect(throws: SnapshotImportError.snapshotIsNewerThanApp("v99_from_the_future")) {
                try SnapshotImporter().prepare(archive, into: directory.appendingPathComponent("work"))
            }
        }
    }

    @Test func refusesSomethingThatIsntASnapshot() throws {
        try withTemporaryDirectory { directory in
            let plain = directory.appendingPathComponent("notes.txt")
            try Data(String(repeating: "not a database. ", count: 64).utf8).write(to: plain)
            let archive = directory.appendingPathComponent("notes.txt.gz")
            try Gzip.compress(fileAt: plain, to: archive)

            #expect(throws: SnapshotImportError.notALiftingCoachDatabase) {
                try SnapshotImporter().prepare(archive, into: directory.appendingPathComponent("work"))
            }
        }
    }

    /// A truncated download inflates into a shorter but structurally valid
    /// SQLite file, so only the trailer catches it. Restoring one would silently
    /// drop the tail of a training history.
    @Test func refusesATruncatedArchive() throws {
        try withTemporaryDirectory { directory in
            let source = try makeDatabase(at: directory.appendingPathComponent("source.sqlite"), workouts: 5)
            let archive = try SnapshotExporter(source)
                .export(to: directory.appendingPathComponent("out")).url

            let whole = try Data(contentsOf: archive)
            let truncated = directory.appendingPathComponent("truncated.gz")
            // Keep the trailer, drop compressed data from the middle: the CRC
            // still claims the whole file.
            var damaged = whole.prefix(whole.count - 8 - 512)
            damaged.append(whole.suffix(8))
            try damaged.write(to: truncated)

            #expect(throws: Gzip.Failure.corrupt) {
                try SnapshotImporter().prepare(truncated, into: directory.appendingPathComponent("work"))
            }
        }
    }

    @Test func refusesAFileThatIsntGzipAtAll() throws {
        try withTemporaryDirectory { directory in
            let bogus = directory.appendingPathComponent("bogus.gz")
            try Data(repeating: 0x41, count: 4096).write(to: bogus)

            #expect(throws: Gzip.Failure.notAGzipArchive) {
                try SnapshotImporter().prepare(bogus, into: directory.appendingPathComponent("work"))
            }
        }
    }

    /// Our writer emits the minimum ten-byte header; the `gzip` command line
    /// writes a filename into it. Reading a snapshot must not depend on it
    /// having been written by us.
    @Test func readsAnArchiveWrittenByTheSystemGzip() throws {
        try withTemporaryDirectory { directory in
            let source = try makeDatabase(at: directory.appendingPathComponent("source.sqlite"), workouts: 2)
            let ours = try SnapshotExporter(source)
                .export(to: directory.appendingPathComponent("out")).url

            // Round the file through the command line so the archive under test
            // carries a header we didn't write — `gzip` records the original
            // filename, which our own writer never does.
            let plain = directory.appendingPathComponent("theirs.sqlite")
            try run("/usr/bin/gunzip", ["-c", ours.path], writingTo: plain)
            try run("/usr/bin/gzip", ["-1", plain.path], writingTo: nil)

            let theirs = directory.appendingPathComponent("theirs.sqlite.gz")
            let prepared = try SnapshotImporter()
                .prepare(theirs, into: directory.appendingPathComponent("work"))
            #expect(prepared.rowCounts["workout"] == 2)
        }
    }
}

private func run(_ tool: String, _ arguments: [String], writingTo output: URL?) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if let output {
        #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
        process.standardOutput = try FileHandle(forWritingTo: output)
    }
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(tool) \(arguments.joined(separator: " ")) failed")
}

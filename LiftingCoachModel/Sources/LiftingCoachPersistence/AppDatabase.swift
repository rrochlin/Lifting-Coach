import Foundation
import GRDB

/// Owns the on-device SQLite database: opening it, running migrations, and
/// handing out a connection.
///
/// Per `notes/Workout App/Backend/Overview.md`, SQLite is the system of record
/// on-device for phase 1 — the tracking loop must work with no server. Sync to a
/// server backend is phase 2 and deliberately has no representation here yet.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Where the app's database lives. Public so a restore can replace the file
    /// at launch, before anything has opened it — `SnapshotImporter.install`
    /// swaps the file underneath, which is only safe with no connection open.
    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("LiftingCoach", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("db.sqlite")
    }

    /// Opens (or creates) the database at the app's standard on-device location.
    public static func onDisk(
        at url: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> AppDatabase {
        let dbURL = try url ?? defaultURL(fileManager: fileManager)

        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabasePool(path: dbURL.path, configuration: config))
    }

    /// An ephemeral in-memory database. Used by tests, and by SwiftUI previews
    /// that need a real store without touching the user's data.
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }
}

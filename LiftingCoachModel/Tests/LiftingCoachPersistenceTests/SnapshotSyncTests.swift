import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

/// Records what was handed to it, so a test can ask how many megabytes actually
/// left the phone rather than only what the coordinator claims it decided.
private final class RecordingUploader: @unchecked Sendable {
    private let lock = NSLock()
    private var _uploads: [SnapshotExporter.Snapshot] = []
    private var _failNext = false

    var uploads: [SnapshotExporter.Snapshot] { lock.withLock { _uploads } }
    var count: Int { lock.withLock { _uploads.count } }

    func failNextUpload() { lock.withLock { _failNext = true } }

    func upload(_ snapshot: SnapshotExporter.Snapshot) throws {
        try lock.withLock {
            if _failNext {
                _failNext = false
                throw UploadFailure.refused
            }
            _uploads.append(snapshot)
        }
    }

    enum UploadFailure: Error { case refused }
}

private struct Harness {
    let database: AppDatabase
    let directory: URL
    let watermarks: InMemoryWatermarkStore
    let uploader: RecordingUploader
    let sync: SnapshotSync
    let userID: UUID
}

private func makeHarness(account: String? = "abc-123") throws -> Harness {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let database = try AppDatabase.onDisk(at: directory.appendingPathComponent("db.sqlite"))
    let users = UserStore(database)
    let user = try users.localUser()

    let watermarks = InMemoryWatermarkStore()
    let uploader = RecordingUploader()
    let sync = SnapshotSync(
        database: database,
        watermarks: watermarks,
        workingDirectory: directory.appendingPathComponent("outbox"),
        account: { account },
        upload: { try uploader.upload($0) }
    )
    return Harness(
        database: database,
        directory: directory,
        watermarks: watermarks,
        uploader: uploader,
        sync: sync,
        userID: user.id
    )
}

/// Something that genuinely changes the exported bytes.
private func logAWorkout(_ harness: Harness, named name: String) throws {
    var workout = Workout(startTime: Date(), notes: name)
    workout.endTime = Date()
    try WorkoutStore(harness.database).save(workout)
}

@Suite("Snapshot sync")
struct SnapshotSyncTests {

    /// Phase 1's whole cost. Nothing is signed in, so nothing is exported —
    /// the mechanism is built and switched off, not built and idling.
    @Test("With no account, nothing is exported at all")
    func doesNothingWithoutAnAccount() async throws {
        let harness = try makeHarness(account: nil)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await harness.sync.markChanged()
        let outcome = try await harness.sync.syncIfNeeded(.enteringBackground)

        #expect(outcome == .skipped(.noAccount))
        #expect(harness.uploader.count == 0)
        #expect(!FileManager.default.fileExists(
            atPath: harness.directory.appendingPathComponent("outbox").path
        ))
    }

    /// Signing in on a phone that already holds a training log is the case where
    /// nothing has "changed" and everything needs to go up.
    @Test("The first sync for an account uploads without being told anything changed")
    func firstSyncUploadsRegardless() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let outcome = try await harness.sync.syncIfNeeded(.signedIn)

        #expect(harness.uploader.count == 1)
        if case .uploaded(let bytes, _) = outcome {
            #expect(bytes > 0)
        } else {
            Issue.record("expected an upload, got \(outcome)")
        }
    }

    /// The cheap filter. Backgrounding happens dozens of times a day and must
    /// not gzip a megabyte each time.
    @Test("Backgrounding with nothing changed does not export")
    func quietBackgroundingIsFree() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try await harness.sync.syncIfNeeded(.signedIn)
        for _ in 0..<5 {
            #expect(try await harness.sync.syncIfNeeded(.enteringBackground) == .skipped(.nothingChanged))
        }
        #expect(harness.uploader.count == 1)
    }

    @Test("A finished workout goes up")
    func changedDataUploads() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try await harness.sync.syncIfNeeded(.signedIn)
        try logAWorkout(harness, named: "Squat day")
        await harness.sync.markChanged()

        let outcome = try await harness.sync.syncIfNeeded(.workoutEnded)
        guard case .uploaded = outcome else {
            Issue.record("expected an upload, got \(outcome)")
            return
        }
        #expect(harness.uploader.count == 2)
        #expect(harness.uploader.uploads[0].sha256 != harness.uploader.uploads[1].sha256)
    }

    /// The second filter, and the one a flag can't do: a workout started and
    /// discarded, or a plan opened and saved untouched, marks the app changed
    /// and leaves the database exactly as it was.
    @Test("A change that leaves the data identical is not re-uploaded")
    func identicalBytesAreNotReuploaded() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try await harness.sync.syncIfNeeded(.signedIn)
        await harness.sync.markChanged()

        #expect(try await harness.sync.syncIfNeeded(.planSaved) == .skipped(.identicalToLastUpload))
        #expect(harness.uploader.count == 1)
    }

    /// And having learned that, it must not re-export to learn it again.
    @Test("Learning the bytes are identical clears the flag")
    func identicalBytesClearTheFlag() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try await harness.sync.syncIfNeeded(.signedIn)
        await harness.sync.markChanged()
        try await harness.sync.syncIfNeeded(.planSaved)

        #expect(try await harness.sync.syncIfNeeded(.enteringBackground) == .skipped(.nothingChanged))
    }

    /// No retry mechanism, on purpose: a failure leaves the watermark alone, so
    /// the next ordinary trigger is the retry.
    @Test("A failed upload is retried by the next trigger")
    func failureLeavesTheWatermarkAlone() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        harness.uploader.failNextUpload()
        await harness.sync.markChanged()
        await #expect(throws: RecordingUploader.UploadFailure.refused) {
            try await harness.sync.syncIfNeeded(.workoutEnded)
        }
        #expect(harness.watermarks.watermark(for: "abc-123") == nil)

        let outcome = try await harness.sync.syncIfNeeded(.enteringBackground)
        guard case .uploaded = outcome else {
            Issue.record("expected the retry to upload, got \(outcome)")
            return
        }
        #expect(harness.uploader.count == 1)
    }

    /// The watermark is keyed by account so signing in as somebody else can't
    /// inherit a claim that their data is already in the bucket.
    @Test("Another account starts with no watermark")
    func watermarksAreScopedToAnAccount() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try await harness.sync.syncIfNeeded(.signedIn)
        #expect(harness.watermarks.watermark(for: "abc-123") != nil)
        #expect(harness.watermarks.watermark(for: "xyz-789") == nil)
    }

    /// It is an unencrypted training log in a temp directory; it lives exactly
    /// as long as the upload does.
    @Test("The uploaded file is not left on disk")
    func leavesNothingBehind() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try await harness.sync.syncIfNeeded(.signedIn)

        let outbox = harness.directory.appendingPathComponent("outbox")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: outbox.path)
        #expect(leftovers.isEmpty)
    }
}

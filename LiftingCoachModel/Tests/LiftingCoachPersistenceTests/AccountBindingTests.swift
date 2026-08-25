import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

private func makeStore() throws -> (UserStore, User) {
    let database = try AppDatabase.inMemory()
    let users = UserStore(database)
    return (users, try users.localUser())
}

@Suite("Account binding")
struct AccountBindingTests {

    @Test("A lifter who has never signed in is bound to nobody")
    func startsUnbound() throws {
        let (users, user) = try makeStore()
        #expect(try users.accountBinding(for: user.id) == nil)
    }

    @Test("Signing in records which account this database belongs to")
    func bindsOnFirstSignIn() throws {
        let (users, user) = try makeStore()
        try users.bind(cognitoSub: "us-east-1:abc-123", to: user.id)
        #expect(try users.accountBinding(for: user.id) == "us-east-1:abc-123")
    }

    @Test("Signing back in as yourself is uneventful")
    func rebindingTheSameAccountIsANoOp() throws {
        let (users, user) = try makeStore()
        try users.bind(cognitoSub: "abc-123", to: user.id)
        try users.bind(cognitoSub: "abc-123", to: user.id)
        #expect(try users.accountBinding(for: user.id) == "abc-123")
    }

    /// The refusal this whole column exists for. The database is the first
    /// account's training log; adopting it under a second identity would upload
    /// one person's sessions into another person's snapshot.
    @Test("A second account cannot take over the log")
    func refusesADifferentAccount() throws {
        let (users, user) = try makeStore()
        try users.bind(cognitoSub: "abc-123", to: user.id)

        #expect(throws: AccountBindingError.boundToAnotherAccount(existing: "abc-123")) {
            try users.bind(cognitoSub: "xyz-789", to: user.id)
        }
        #expect(try users.accountBinding(for: user.id) == "abc-123")
    }

    /// `UserRow` deliberately doesn't carry `cognitoSub`, so `save(_:)` writes
    /// every other column and leaves the binding alone. That is load-bearing
    /// rather than incidental — saving a bodyweight or a renamed lifter must
    /// not be able to sign the phone out — so it gets pinned here.
    @Test("Saving the lifter does not clear the binding")
    func savingAUserPreservesTheBinding() throws {
        let (users, user) = try makeStore()
        try users.bind(cognitoSub: "abc-123", to: user.id)

        var renamed = user
        renamed.name = "Rob"
        try users.save(renamed)

        #expect(try users.accountBinding(for: user.id) == "abc-123")
        #expect(try users.fetch(id: user.id)?.name == "Rob")
    }

    /// A restore replaces the whole file, so the binding travels with the
    /// snapshot rather than being patched in afterwards. This is what makes
    /// "sign in on a fresh phone" land bound without a second step.
    @Test("The binding travels inside a snapshot")
    func bindingSurvivesASnapshotRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sourceURL = directory.appendingPathComponent("source.sqlite")
        let source = try AppDatabase.onDisk(at: sourceURL)
        let users = UserStore(source)
        let user = try users.localUser()
        try users.bind(cognitoSub: "abc-123", to: user.id)

        let snapshot = try SnapshotExporter(source).export(to: directory, named: "out")

        let restoredURL = directory.appendingPathComponent("restored.sqlite")
        let importer = SnapshotImporter()
        let prepared = try importer.prepare(snapshot.url, into: directory, named: "in")
        try importer.install(prepared, replacing: restoredURL)

        let restored = try AppDatabase.onDisk(at: restoredURL)
        #expect(try UserStore(restored).accountBinding(for: user.id) == "abc-123")
    }
}

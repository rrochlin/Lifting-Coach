import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func makeStore() throws -> (UserStore, User) {
    let database = try AppDatabase.inMemory()
    try ExerciseStore(database).save(ExerciseCatalog.seed)
    let users = UserStore(database, calendar: calendar)
    return (users, try users.localUser())
}

@Suite("Unit preference")
struct UnitPreferenceTests {

    @Test("A new lifter reads weights in pounds")
    func defaultsToPounds() throws {
        let (_, user) = try makeStore()
        #expect(user.preferredUnit == .pounds)
    }

    @Test("The unit preference survives a round trip")
    func preferredUnitRoundTrips() throws {
        let (users, user) = try makeStore()

        try users.setPreferredUnit(.kilograms, for: user.id)

        #expect(try users.fetch(id: user.id)?.preferredUnit == .kilograms)
        #expect(try users.localUser().preferredUnit == .kilograms)
    }

    @Test("Switching units rewrites nothing that was already logged")
    func switchingUnitsLeavesHistoryAlone() throws {
        let (users, user) = try makeStore()
        let squat = ExerciseCatalog.seed[0]
        try users.recordBodyWeight(Measurement(value: 198.4, unit: .pounds), for: user.id)
        try users.recordAchievedMax(
            AchievedMax(weight: Measurement(value: 455, unit: .pounds), date: Date()),
            exerciseId: squat.id,
            for: user.id
        )

        try users.setPreferredUnit(.kilograms, for: user.id)

        // The whole claim the Profile screen makes to the lifter: this is a
        // reading preference, not a conversion of their training history. The
        // pounds are still pounds on disk; the app converts on the way out.
        let reloaded = try #require(try users.fetch(id: user.id))
        #expect(reloaded.currentBodyWeight == Measurement(value: 198.4, unit: .pounds))
        #expect(reloaded.max(.achieved, for: squat.id) == Measurement(value: 455, unit: .pounds))
        #expect(reloaded.preferredUnit == .kilograms)
    }

    @Test("Saving the whole lifter carries the preference with it")
    func savePersistsPreference() throws {
        let (users, user) = try makeStore()

        var edited = user
        edited.preferredUnit = .kilograms
        edited.name = "Rob"
        try users.save(edited)

        let reloaded = try #require(try users.fetch(id: user.id))
        #expect(reloaded.preferredUnit == .kilograms)
        #expect(reloaded.name == "Rob")
    }
}

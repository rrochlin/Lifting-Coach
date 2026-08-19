import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

@Suite("Data export")
struct DataExporterTests {

    private func fixture() throws -> (AppDatabase, User) {
        let database = try AppDatabase.inMemory()
        try ExerciseStore(database).save(ExerciseCatalog.seed)
        let user = try UserStore(database).localUser()
        return (database, user)
    }

    @Test("The archive carries the log, the maxes and the plan")
    func exportsEverything() throws {
        let (database, user) = try fixture()
        let squat = ExerciseCatalog.seed[0]

        var session = WorkoutSession.adHoc(at: Date())
        session.addExercise(squat, sets: 2)
        try WorkoutStore(database).save(session.workout)

        try UserStore(database).recordAchievedMax(
            AchievedMax(weight: Measurement(value: 405, unit: .pounds), date: Date()),
            exerciseId: squat.id,
            for: user.id
        )
        try PlanStore(database).save(
            WorkoutBlock(
                program: [Date(): [PlannedWorkout(date: Date())]],
                startDate: Date(),
                notes: "Block 1"
            ),
            userId: user.id
        )

        let archive = try DataExporter(database).export(for: user.id)

        #expect(archive.formatVersion == DataExport.currentFormatVersion)
        #expect(archive.workouts.count == 1)
        #expect(archive.counts.workouts == 1)
        #expect(archive.counts.sets == 2)
        #expect(archive.counts.blocks == 1)
        #expect(archive.counts.plannedWorkouts == 1)
        #expect(archive.user.achievedMaxes?[squat.id]?.count == 1)
        #expect(archive.plan.blocks?.first?.notes == "Block 1")
    }

    /// An archive that can't be read back isn't an archive. Nothing imports one
    /// yet — that's phase 2 — but the file has to be capable of it, which is the
    /// difference between a backup and a report.
    @Test("The JSON round-trips back into the same values")
    func jsonRoundTrips() throws {
        let (database, user) = try fixture()
        let squat = ExerciseCatalog.seed[0]

        var session = WorkoutSession.adHoc(at: Date())
        session.addExercise(squat, sets: 1)
        let setID = session.exerciseGroups[0][0].sets?[0].id
        session.completeSet(
            id: try #require(setID),
            reps: 5,
            weight: Measurement(value: 315, unit: .pounds),
            rpe: 8
        )
        try WorkoutStore(database).save(session.workout)

        let data = try DataExporter(database).exportJSON(for: user.id)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DataExport.self, from: data)

        let set = try #require(decoded.workouts.first?.allSets.first)
        #expect(set.reps == 5)
        #expect(set.weight?.value == 315)
        #expect(set.weight?.unit == .pounds)
        #expect(set.rpe == 8)
        #expect(decoded.counts.sets == 1)
    }

    @Test("Exporting a lifter the database doesn't have is an error, not an empty file")
    func unknownUserThrows() throws {
        let (database, _) = try fixture()

        #expect(throws: DataExporter.ExportError.noSuchUser) {
            try DataExporter(database).export(for: UUID())
        }
    }

    @Test("The filename sorts chronologically and names the app")
    func filename() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let archive = DataExport(
            exportedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 19))!,
            user: User(id: UUID(), name: "", email: ""),
            workouts: [],
            plan: WorkoutPlan()
        )

        #expect(archive.suggestedFilename(calendar: calendar) == "lifting-coach-2026-08-19.json")
    }
}

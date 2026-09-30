import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

/// Search quality, measured against real queries rather than invented ones.
///
/// **Where the queries come from.** `scripts/data/strong_exercise_map.json` is
/// the reviewed translation of five years of the owner's own logging: 149 names
/// he actually typed into Strong, each paired with the catalog entry *a human
/// chose* for it. That makes it the one thing in this repo that can answer "is
/// search any good" without anybody grading their own homework — the answers
/// were written for a different purpose, before this module existed.
///
/// **What the thresholds are for.** Search quality is the kind of thing that
/// rots silently: an innocent-looking change to the stemmer or one more alias
/// can cost ten points of recall and nothing goes red. These floors sit a
/// little under the measured numbers, so ordinary tuning passes and a
/// regression fails. If a change legitimately improves things, raise them.
///
/// The mapping lives outside the Swift package, so this reads it by path and
/// skips rather than fails when it isn't there — a standalone checkout of the
/// package is not a broken one.
@Suite("Exercise search benchmark")
struct ExerciseSearchBenchmarkTests {

    private struct Mapping: Decodable {
        struct Entry: Decodable {
            let name: String
            let slug: String?
        }
        let entries: [Entry]
    }

    /// Real query → the slug a person picked for it.
    private static func groundTruth() -> [(query: String, slug: String)]? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("scripts/data/strong_exercise_map.json")
        guard let data = try? Data(contentsOf: url),
              let mapping = try? JSONDecoder().decode(Mapping.self, from: data)
        else { return nil }
        // Entries resolving to `create` or `openChoice` name no catalog entry,
        // so there is no right answer to score against.
        return mapping.entries.compactMap { entry in
            entry.slug.map { (entry.name, $0) }
        }
    }

    private func catalog() throws -> [Exercise] {
        let database = try AppDatabase.inMemory()
        _ = try CatalogImporter(database).importCatalog(try CatalogImporter.bundledCatalog)
        return try ExerciseStore(database).fetchAll()
    }

    private struct Measurement {
        var queries = 0
        var top1 = 0
        var top5 = 0
        var found = 0
        var empty = 0
        var results = 0

        var recall: Double { Double(found) / Double(queries) }
        var topFive: Double { Double(top5) / Double(queries) }
        var emptyRate: Double { Double(empty) / Double(queries) }
        var averageResults: Double { Double(results) / Double(queries) }

        var summary: String {
            String(
                format: "%d queries · top1 %.0f%% · top5 %.0f%% · found %.0f%% · empty %.0f%% · avg %.0f results",
                queries, Double(top1) / Double(queries) * 100, topFive * 100,
                recall * 100, emptyRate * 100, averageResults
            )
        }
    }

    private func measure(_ index: ExerciseSearchIndex,
                         _ truth: [(query: String, slug: String)],
                         _ bySlug: [String: Exercise]) -> Measurement {
        var result = Measurement()
        for (query, slug) in truth {
            guard let wanted = bySlug[slug] else { continue }
            result.queries += 1
            let ranked = index.ranked(query).map(\.exercise.id)
            result.results += ranked.count
            if ranked.isEmpty { result.empty += 1 }
            if let position = ranked.firstIndex(of: wanted.id) {
                result.found += 1
                if position == 0 { result.top1 += 1 }
                if position < 5 { result.top5 += 1 }
            }
        }
        return result
    }

    @Test("Search finds what five years of real queries were asking for")
    func recallAgainstRealQueries() throws {
        guard let truth = Self.groundTruth() else { return }
        let exercises = try catalog()
        let bySlug = Dictionary(
            exercises.compactMap { e in e.sourceSlug.map { ($0, e) } },
            uniquingKeysWith: { first, _ in first }
        )
        let index = ExerciseSearchIndex(exercises)
        let measured = measure(index, truth, bySlug)

        print("catalog \(exercises.count) · \(measured.summary)")

        #expect(measured.queries > 100, "benchmark shrank — is the mapping still intact?")
        // Floors, not targets. Measured at 99% / 96% / 1% when written.
        #expect(measured.recall >= 0.95, "recall regressed to \(measured.summary)")
        #expect(measured.topFive >= 0.92, "ranking regressed to \(measured.summary)")
        #expect(measured.emptyRate <= 0.04, "empty results regressed to \(measured.summary)")
    }

    @Test("Substring search is the thing being replaced, and it is much worse")
    func substringSearchIsWorse() throws {
        // Pins the reason this module exists. If someone ever reverts to
        // `contains`, this is the number they're accepting: it answered four in
        // five of these queries with a blank screen (Core Tenets §10).
        guard let truth = Self.groundTruth() else { return }
        let exercises = try catalog()
        var empty = 0
        for (query, _) in truth where !exercises.contains(where: {
            $0.name.localizedCaseInsensitiveContains(query)
        }) {
            _ = query
            empty += 1
        }
        let rate = Double(empty) / Double(truth.count)
        print(String(format: "substring search: %.0f%% of real queries return nothing", rate * 100))
        #expect(rate > 0.5)
    }

    @Test("A rarer word decides the order")
    func rarerWordsWeighMore() throws {
        let exercises = try catalog()
        let index = ExerciseSearchIndex(exercises)

        // Caught on screen, not in a test: "barbell incline press" put
        // *Barbell Shoulder Press* second, level with *Incline Dumbbell Press*.
        // Both matched two terms of three, an unweighted mean scored them
        // identically, and the alphabet broke the tie. `incline` appears in a
        // fraction of the names `press` and `barbell` do, so it is the word
        // that was actually narrowing the catalog.
        let ranked = index.ranked("barbell incline press").map(\.exercise.name)
        #expect(ranked.first == "Barbell Incline Bench Press - Medium Grip")
        for name in ranked.prefix(5) {
            #expect(name.localizedCaseInsensitiveContains("incline"),
                    "\(name) ranked above lifts that match the narrowing term")
        }
    }

    @Test("Ranking a query against the whole catalog stays interactive")
    func latency() throws {
        let exercises = try catalog()
        let index = ExerciseSearchIndex(exercises)
        // Typing "barbell incline press" one character at a time — every
        // keystroke re-ranks, so the per-query cost is the thing that decides
        // whether the list keeps up with the keyboard.
        let typed = "barbell incline press"
        let prefixes = (1...typed.count).map { String(typed.prefix($0)) }

        let started = Date()
        var iterations = 0
        for _ in 0..<10 {
            for prefix in prefixes {
                _ = index.ranked(prefix)
                iterations += 1
            }
        }
        let each = Date().timeIntervalSince(started) / Double(iterations) * 1000
        print(String(format: "ranked %d exercises in %.2f ms per keystroke", exercises.count, each))
        // Generous: this is a debug build on whatever CI happens to be running.
        // It's here to catch an accidental quadratic, not to police milliseconds.
        #expect(each < 50)
    }

    @Test("Building the index over the whole catalog is cheap enough to do once")
    func indexBuild() throws {
        let exercises = try catalog()
        let started = Date()
        for _ in 0..<10 { _ = ExerciseSearchIndex(exercises) }
        let each = Date().timeIntervalSince(started) / 10 * 1000
        print(String(format: "built index over %d exercises in %.1f ms", exercises.count, each))
        #expect(each < 500)
    }
}

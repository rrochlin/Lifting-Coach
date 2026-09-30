import Foundation
import Testing
@testable import LiftingCoachModel

@Suite("Exercise search")
struct ExerciseSearchTests {

    // A handful of real catalog entries, enough to exercise ranking without
    // standing in for the benchmark — that runs against all 873 and lives in
    // the persistence suite, where the bundled catalog is.
    private static let catalog: [Exercise] = [
        Exercise(id: 1, name: "Barbell Incline Bench Press - Medium Grip",
                 muscleGroup: "Chest", equipment: "barbell",
                 primaryMuscles: ["chest"], mechanic: "compound"),
        Exercise(id: 2, name: "Incline Dumbbell Press", muscleGroup: "Chest",
                 equipment: "dumbbell", primaryMuscles: ["chest"]),
        Exercise(id: 3, name: "Barbell Squat", muscleGroup: "Quadriceps",
                 equipment: "barbell", primaryMuscles: ["quadriceps"]),
        Exercise(id: 4, name: "Barbell Hack Squat", muscleGroup: "Quadriceps",
                 equipment: "barbell", primaryMuscles: ["quadriceps"]),
        Exercise(id: 5, name: "Pullups", muscleGroup: "Lats",
                 equipment: "body only", primaryMuscles: ["lats"]),
        Exercise(id: 6, name: "Butterfly", muscleGroup: "Chest",
                 equipment: "machine", primaryMuscles: ["chest"]),
        Exercise(id: 7, name: "Barbell Shoulder Press", muscleGroup: "Shoulders",
                 equipment: "barbell", primaryMuscles: ["shoulders"]),
        Exercise(id: 8, name: "Cable Crossover", muscleGroup: "Chest",
                 equipment: "cable", primaryMuscles: ["chest"]),
        Exercise(id: 9, name: "Leverage Chest Press", muscleGroup: "Chest",
                 equipment: "machine", primaryMuscles: ["chest"]),
    ]

    private static let index = ExerciseSearchIndex(catalog)

    private func names(_ query: String) -> [String] {
        Self.index.ranked(query).map(\.exercise.name)
    }

    // MARK: - The reported failure

    @Test("A query whose words are scattered through the name still finds it")
    func scatteredWordsMatch() {
        // The whole reason this module exists: substring search returned
        // nothing here, because "incline press" is not contiguous in the name.
        #expect(names("Barbell incline press").first == "Barbell Incline Bench Press - Medium Grip")
    }

    @Test("Word order doesn't matter")
    func orderIndependent() {
        #expect(names("press incline barbell").first == "Barbell Incline Bench Press - Medium Grip")
    }

    // MARK: - Ranking

    @Test("The name the query fully accounts for outranks one with extra words")
    func tighterMatchWins() {
        // Both match every term; "Barbell Hack Squat" has a word the lifter
        // never asked for, so it ranks second rather than being excluded.
        let results = names("barbell squat")
        #expect(results.first == "Barbell Squat")
        #expect(results.contains("Barbell Hack Squat"))
    }

    @Test("A name match outranks a metadata match")
    func nameBeatsMetadata() {
        // Every entry here is a chest exercise, so all of them match "chest"
        // somewhere. The one that says so in its *name* comes first.
        let results = names("chest")
        #expect(results.first == "Leverage Chest Press")
        #expect(results.contains("Butterfly"))
    }

    @Test("A term the entry doesn't answer keeps it out of the results")
    func everyTermHasToPull() {
        // Butterfly is a chest exercise but is not a chest *press*, and the
        // mean-of-terms score is what excludes it rather than ranking it low.
        #expect(!names("chest press").contains("Butterfly"))
    }

    @Test("Metadata finds a lift whose name omits the word")
    func metadataMatches() {
        // "Butterfly" says nothing about being a machine; its equipment does.
        #expect(names("machine chest").contains("Butterfly"))
    }

    // MARK: - Vocabulary

    @Test("Abbreviations expand")
    func abbreviations() {
        #expect(names("incline db press").first == "Incline Dumbbell Press")
        #expect(names("bb squat").first == "Barbell Squat")
    }

    @Test("Compound words match either spelling")
    func compounds() {
        #expect(names("pull up").first == "Pullups")
        #expect(names("pullup").first == "Pullups")
        #expect(names("pull ups").first == "Pullups")
    }

    @Test("Authored aliases bridge vocabulary the catalog lacks")
    func aliases() {
        // No amount of string similarity gets from "pec deck" to "Butterfly",
        // and the catalog never once says "overhead press".
        #expect(names("pec deck").first == "Butterfly")
        #expect(names("ohp").first == "Barbell Shoulder Press")
        #expect(names("overhead press").first == "Barbell Shoulder Press")
        #expect(names("cable fly").first == "Cable Crossover")
    }

    @Test("Typos still find the lift")
    func typos() {
        #expect(names("barbel squat").contains("Barbell Squat"))
        #expect(names("dumbell press").contains("Incline Dumbbell Press"))
    }

    // MARK: - Boundaries

    @Test("An empty query ranks nothing, leaving the caller's own order alone")
    func emptyQuery() {
        // Not "everything": with no search term the picker's usage ordering is
        // the right answer, and this has no opinion to add.
        #expect(Self.index.ranked("").isEmpty)
        #expect(Self.index.ranked("   ").isEmpty)
        #expect(Self.index.ranked("!!").isEmpty)
    }

    @Test("A query matching nothing returns nothing rather than the catalog")
    func noMatch() {
        #expect(Self.index.ranked("kayaking").isEmpty)
    }

    @Test("Search never invents or drops an entry")
    func resultsAreCatalogEntries() {
        let results = Self.index.ranked("press")
        #expect(!results.isEmpty)
        #expect(Set(results.map(\.exercise.id)).count == results.count)
        for result in results {
            #expect(Self.catalog.contains(result.exercise))
        }
    }

    @Test("Results come back best first")
    func sortedByScore() {
        let scores = Self.index.ranked("barbell press").map(\.score)
        #expect(scores == scores.sorted(by: >))
    }
}

@Suite("Exercise search text")
struct ExerciseSearchTextTests {

    @Test("Stemming is idempotent, which is what lets both sides meet")
    func stemmingIsIdempotent() {
        // The reason this isn't a Porter stemmer. Porter takes `press` to
        // `pres` and `presses` to `press`, so a query and a catalog name
        // stemmed independently would never land on the same token.
        for word in ["press", "presses", "squat", "squats", "fly", "flies",
                     "crunch", "crunches", "raise", "raises", "cross", "lats",
                     "triceps", "tricep", "pullups", "abdominals"] {
            let once = ExerciseSearchText.stem(word)
            #expect(ExerciseSearchText.stem(once) == once, "\(word) → \(once) is not stable")
        }
    }

    @Test("Plurals and singulars stem together")
    func pluralsMeet() {
        #expect(ExerciseSearchText.stem("squats") == ExerciseSearchText.stem("squat"))
        #expect(ExerciseSearchText.stem("presses") == ExerciseSearchText.stem("press"))
        #expect(ExerciseSearchText.stem("crunches") == ExerciseSearchText.stem("crunch"))
        #expect(ExerciseSearchText.stem("triceps") == ExerciseSearchText.stem("tricep"))
    }

    @Test("Double-s and -us words aren't mistaken for plurals")
    func notEveryTrailingSIsAPlural() {
        #expect(ExerciseSearchText.stem("press") == "press")
        #expect(ExerciseSearchText.stem("cross") == "cross")
        #expect(ExerciseSearchText.stem("gluteus") == "gluteus")
    }

    @Test("Punctuation separates words rather than joining them")
    func punctuationSeparates() {
        // "Bench Press (Barbell)" and "Barbell Bench Press - Medium Grip" have
        // to tokenize into comparable words for either to find the other.
        #expect(ExerciseSearchText.tokens("Bench Press (Barbell)") == ["bench", "press", "barbell"])
        #expect(ExerciseSearchText.tokens("Barbell Bench Press - Medium Grip")
                == ["barbell", "bench", "press", "medium", "grip"])
    }

    @Test("Diacritics fold")
    func diacritics() {
        #expect(ExerciseSearchText.tokens("Pull-Up") == ["pull", "up"])
        #expect(ExerciseSearchText.tokens("¾ Sit-Up") == ["sit", "up"])
    }

    @Test("The query pipeline and the catalog pipeline agree")
    func bothSidesTokenizeAlike() {
        // Nothing is special-cased on one side; that's what makes `pushups` in
        // the catalog and `push up` in the field arrive at the same tokens.
        #expect(ExerciseSearchText.tokens("Pushups") == ExerciseSearchText.queryTokens("push up"))
        #expect(ExerciseSearchText.tokens("Triceps Pushdown") == ExerciseSearchText.queryTokens("tricep push down"))
    }

    @Test("Aliases apply longest phrase first")
    func longestAliasWins() {
        // "nordic" alone maps to a shorter phrase; the three-word key has to
        // consume the query before the one-word key can claim part of it.
        #expect(ExerciseSearchText.applyAliases("nordic leg curl") == "natural glute ham raise")
    }

    @Test("Edit distance abandons past its budget")
    func editDistanceBudget() {
        #expect(ExerciseSearchText.editDistance("squat", "squat", budget: 1) == 0)
        #expect(ExerciseSearchText.editDistance("squat", "squats", budget: 1) == 1)
        #expect(ExerciseSearchText.editDistance("squat", "deadlift", budget: 1) == nil)
    }

    @Test("Short words aren't fuzzy-matched")
    func shortWordsAreExactOnly() {
        // At four characters an edit is a different word, not a typo.
        #expect(ExerciseSearchText.similarity("curl", "curb") == nil)
        #expect(ExerciseSearchText.similarity("barbel", "barbell") != nil)
    }
}

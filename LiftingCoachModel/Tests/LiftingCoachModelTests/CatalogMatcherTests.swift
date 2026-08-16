import Foundation
import Testing
@testable import LiftingCoachModel

private func c(_ name: String, _ slug: String? = nil) -> CatalogMatcher.Candidate {
    CatalogMatcher.Candidate(name: name, sourceSlug: slug ?? name.replacingOccurrences(of: " ", with: "_"))
}

@Suite("CatalogMatcher")
struct CatalogMatcherTests {

    /// A slice of the real free-exercise-db corpus, chosen specifically because
    /// it contains the near-miss candidates that broke earlier, simpler scoring
    /// attempts (see the type's doc comment) — a plain barbell deadlift sitting
    /// next to an "Axle Deadlift" that alphabetically precedes it, a "Bench
    /// Dips" that shares only the word "bench" with an actual bench press, etc.
    private let corpus: [CatalogMatcher.Candidate] = [
        c("Axle Deadlift"),
        c("Barbell Deadlift"),
        c("Deficit Deadlift"),
        c("Romanian Deadlift"),
        c("Barbell Bench Press - Medium Grip"),
        c("Bench Dips"),
        c("Close-Grip Barbell Bench Press"),
        c("Barbell Squat"),
        c("Barbell Full Squat"),
        c("Barbell Hack Squat"),
        c("Weighted Pull Ups"),
        c("Farmer's Walk"),
        c("Heavy Bag Thrust"),
    ]

    @Test("Picks the plain barbell variant over an equipment-specific one on a tie")
    func prefersBarbellOnTie() {
        // Both "Axle Deadlift" and "Barbell Deadlift" share only the word
        // "deadlift" with the source — without a tiebreak, whichever appears
        // first in the corpus wins, which is the wrong lift.
        let match = CatalogMatcher.match("Deadlift — heavy (straight bar)", against: corpus)
        #expect(match?.name == "Barbell Deadlift")
    }

    @Test("A modifier-only overlap is not enough to match")
    func modifierOnlyOverlapDoesNotMatch() {
        // Regression: "heavy" alone matched "Heavy Bag Thrust" before the
        // movement-word gate existed. "Heavy" isn't a movement.
        let match = CatalogMatcher.match("Deadlift — heavy (straight bar)", against: [c("Heavy Bag Thrust")])
        #expect(match == nil)
    }

    @Test("Bench press doesn't match bench dips on the word \"bench\" alone when a better option exists")
    func prefersFullerOverlap() {
        let match = CatalogMatcher.match(
            "Close-grip bench (straight bar, shoulder-width)",
            against: corpus
        )
        #expect(match?.name == "Close-Grip Barbell Bench Press")
    }

    @Test("Abbreviations expand before matching")
    func expandsAbbreviations() {
        #expect(CatalogMatcher.match("RDL", against: corpus)?.name == "Romanian Deadlift")
        #expect(CatalogMatcher.match("Deficit DL (1.5\")", against: corpus)?.name == "Deficit Deadlift")
    }

    @Test("A name with no movement word at all matches nothing")
    func noMovementWordMeansNoMatch() {
        // "Triceps + biceps" and similar compound/ambiguous entries from the
        // real program are exactly this case — correctly left unmatched rather
        // than guessed at (Core Tenets §10).
        #expect(CatalogMatcher.match("Triceps + biceps", against: corpus) == nil)
        #expect(CatalogMatcher.match("Core (ab wheel / hanging leg raise)", against: corpus) == nil)
    }

    @Test("Parenthetical content doesn't leak into matching")
    func parentheticalsAreStripped() {
        // Without stripping, "(comp stance)" would contribute "comp" ->
        // "competition" as a token; that shouldn't be what decides the match.
        let match = CatalogMatcher.match("Squat — volume (comp stance)", against: corpus)
        #expect(match?.name == "Barbell Squat" || match?.name == "Barbell Full Squat")
    }

    @Test("An empty candidate list matches nothing")
    func emptyCandidatesMatchNothing() {
        #expect(CatalogMatcher.match("Bench Press", against: []) == nil)
    }
}

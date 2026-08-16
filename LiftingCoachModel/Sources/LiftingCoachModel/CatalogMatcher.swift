import Foundation

/// Best-effort matching between a manually-named exercise (a program import, a
/// hand-typed catalog entry) and a canonical catalog exercise, so the former can
/// be enriched with the latter's metadata without changing its identity.
///
/// **Deliberately low-grade.** This is keyword overlap against a short
/// hand-written table of movement words, not semantic search. It exists to get
/// *some* exercises enriched now, cheaply, not to get all of them right — real
/// programming names ("Bench press — heavy (paused, comp grip)") don't line up
/// 1:1 with a canonical database's names ("Barbell Bench Press - Medium Grip"),
/// and often can't: some source names describe more than one exercise ("Triceps
/// + biceps"), or none at all ("Walk with wife (recovery)"). A more capable
/// matcher (embeddings, an LLM call) is future work if this stops being good
/// enough — see `Roadmap.md`.
///
/// **Never silently wrong.** `match` requires the two names to share at least
/// one word that actually names a movement pattern (`bench`, `squat`, `row`...).
/// Overlapping only on modifiers ("heavy", "paused", "comp") is not enough to
/// match — that produced real false positives while building this (a heavy
/// deadlift matched to "Heavy Bag Thrust" on the word "heavy" alone) and is
/// worse than leaving the exercise unenriched (Core Tenets §10).
public enum CatalogMatcher {

    /// Words English lifting jargon doesn't use to distinguish a movement, so
    /// they're dropped before scoring — otherwise near-universal words like "or"
    /// or "with" would inflate every candidate's overlap equally.
    private static let stopwords: Set<String> = [
        "or", "the", "to", "a", "and", "s", "of", "with", "off", "from", "no", "if",
    ]

    /// Common lifting shorthand, expanded before matching. Small and
    /// hand-maintained on purpose — add to this as real misses turn up rather
    /// than trying to anticipate every abbreviation up front.
    private static let abbreviations: [String: String] = [
        "rdl": "romanian deadlift",
        "dl": "deadlift",
        "bb": "barbell",
        "db": "dumbbell",
        "ohp": "overhead press",
        "comp": "competition",
    ]

    /// The gate: a candidate is only considered if it shares one of these with
    /// the source name. Modifiers, equipment, and tempo words don't count.
    private static let movementWords: Set<String> = [
        "bench", "squat", "deadlift", "press", "row", "pulldown", "pull", "push",
        "curl", "dip", "walk", "extension", "raise", "lunge", "clean", "snatch",
        "chin", "fly", "flye", "thrust", "crunch", "plank", "carry", "shrug",
        "stretch",
    ]

    /// Normalizes a name to a token set: strips parenthetical asides, lowercases,
    /// splits on non-alphanumerics, drops stopwords, expands abbreviations.
    public static func tokens(_ name: String) -> Set<String> {
        var withoutParens = ""
        var depth = 0
        for char in name {
            if char == "(" { depth += 1; continue }
            if char == ")" { depth = max(0, depth - 1); continue }
            withoutParens.append(depth == 0 ? char : " ")
        }

        let words = withoutParens
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !stopwords.contains($0) && $0.count > 1 }

        var result: Set<String> = []
        for word in words {
            if let expansion = abbreviations[word] {
                result.formUnion(expansion.split(separator: " ").map(String.init))
            } else {
                result.insert(word)
            }
        }
        return result
    }

    /// A candidate to match against — just enough to score and identify it.
    public struct Candidate: Sendable {
        public var name: String
        public var sourceSlug: String

        public init(name: String, sourceSlug: String) {
            self.name = name
            self.sourceSlug = sourceSlug
        }
    }

    /// The best candidate for `name`, or `nil` if nothing clears the movement-
    /// word gate.
    ///
    /// Scoring, in priority order: most shared movement words, then most shared
    /// words overall, then — as a tiebreak for the common case where several
    /// candidates tie on both (e.g. every "___ Deadlift" variant sharing just
    /// "deadlift") — preference for a plain barbell candidate over an
    /// equipment-specific one (a straight-bar lift described with no equipment
    /// mentioned is barbell work by default; testing this against a real
    /// program's exercise list is what surfaced "Axle Deadlift" winning that tie
    /// ahead of "Barbell Deadlift" purely by appearing first in the source data).
    public static func match(_ name: String, against candidates: [Candidate]) -> Candidate? {
        let source = tokens(name)
        var best: (score: (Int, Int, Int), candidate: Candidate)?

        for candidate in candidates {
            let candidateTokens = tokens(candidate.name)
            guard !candidateTokens.isEmpty else { continue }

            let overlap = source.intersection(candidateTokens)
            let movementOverlap = overlap.intersection(movementWords)
            guard !movementOverlap.isEmpty else { continue }

            let barbellBonus = candidateTokens.contains("barbell") ? 1 : 0
            let score = (movementOverlap.count, overlap.count, barbellBonus)

            if best == nil || score > best!.score {
                best = (score, candidate)
            }
        }

        return best?.candidate
    }
}

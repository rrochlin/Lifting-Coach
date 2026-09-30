import Foundation

/// Finding a lift in a catalog of ~870 by typing part of its name.
///
/// **Why this exists at all.** Search was one `localizedCaseInsensitiveContains`
/// against the whole name, which requires the lifter to type a contiguous run of
/// the catalog's exact wording. Measured against the 130 real queries in
/// `scripts/data/strong_exercise_map.json` — names the owner actually typed for
/// five years, each paired with the entry a human chose for it — that returned
/// **nothing at all for 81% of them**. "Barbell incline press" finding zero
/// results while *Barbell Incline Bench Press - Medium Grip* sits in the catalog
/// is the typical case, not an unlucky one.
///
/// **Why not embeddings.** Both of Apple's on-device options were built against
/// this catalog and measured before this was written, and both are worse than
/// the string matching they'd replace:
/// - `NLEmbedding` puts `squat` and `deadlift` at distance 0.721 — nearer than
///   any true synonym pair probed — and has no vector at all for `pushdown`,
///   `abductor` or `nordic`. Its nearest neighbours for `barbell` are *pullup,
///   gym, aerobics*. It encodes topical relatedness, not synonymy, so every gym
///   word is near every other one.
/// - `NLContextualEmbedding` over all 873 names scores everything between 0.93
///   and 0.96 — no discriminating power on short formulaic strings. It ranks
///   *Pec Deck* → Butterfly at 851 of 873, answers "Barbell incline press" with
///   *Barbell Shrug*, and costs 9 ms per string to embed.
///
/// FTS5 is available in the system SQLite (verified, with the porter tokenizer)
/// and is also the wrong tool here: at 873 rows it buys scale nobody needs while
/// putting ranking in SQL, where neither the field weighting nor the fuzzy tier
/// below can be expressed. Staying pure Swift keeps this in the model package,
/// testable with no database — the same shape as `SetSuggestion`.
///
/// **This ranks candidates for a person to choose from.** It is emphatically not
/// the name matching `Concepts.md` forbids: nothing here decides what a program
/// *means* by a name. That rule is about deriving an exercise's identity at load
/// time, where the answer was always available to be authored. This proposes a
/// sorted list to a lifter who then taps one (Core Tenets §1).
public enum ExerciseSearch {

    /// Score below which a match isn't worth showing. Tuned against the
    /// benchmark: high enough that a one-word query doesn't return a third of
    /// the catalog, low enough that a two-word query missing one word survives.
    public static let cutoff: Double = 0.55
}

// MARK: - Index

/// A catalog with its tokens already computed.
///
/// Built once when the exercise list loads rather than per keystroke: the
/// tokenizing is the expensive half (873 names, and the query is three words),
/// and redoing it on every character typed is the difference between a list that
/// keeps up with the keyboard and one that doesn't.
public struct ExerciseSearchIndex: Sendable {

    /// One catalog entry, pre-tokenized.
    struct Entry: Sendable {
        let exercise: Exercise
        /// Tokens of the name — where a match counts for full score.
        let name: [String]
        /// Equipment, muscles, mechanic, category. A match here is real but
        /// weaker: "cable" should find cable lifts whose names omit the word,
        /// without letting one metadata hit outrank a name hit. Weighted so
        /// that a query made *entirely* of metadata words — "machine chest" —
        /// still clears the cutoff, since that's a legitimate way to search.
        let meta: Set<String>
    }

    let entries: [Entry]
    /// How many catalog names each token appears in. What makes a rare word
    /// count for more than a common one — see `weight(for:)`.
    let documentFrequency: [String: Int]

    public init(_ exercises: [Exercise]) {
        entries = exercises.map { exercise in
            var meta: Set<String> = []
            meta.formUnion(ExerciseSearchText.tokens(exercise.muscleGroup))
            if let equipment = exercise.equipment {
                meta.formUnion(ExerciseSearchText.tokens(equipment))
            }
            for muscle in exercise.primaryMuscles ?? [] {
                meta.formUnion(ExerciseSearchText.tokens(muscle))
            }
            if let mechanic = exercise.mechanic {
                meta.formUnion(ExerciseSearchText.tokens(mechanic))
            }
            if let category = exercise.category {
                meta.formUnion(ExerciseSearchText.tokens(category))
            }
            return Entry(
                exercise: exercise,
                name: ExerciseSearchText.tokens(exercise.name),
                meta: meta
            )
        }
        var frequency: [String: Int] = [:]
        for entry in entries {
            for token in Set(entry.name) { frequency[token, default: 0] += 1 }
        }
        documentFrequency = frequency
    }

    /// How much a query term counts, by how rare it is in the catalog.
    ///
    /// Without this every term weighs the same, and matching two words of three
    /// scores identically no matter *which* one was missed — so "barbell
    /// incline press" ranked *Barbell Shoulder Press* level with *Incline
    /// Dumbbell Press*, both on two of three, and the alphabet broke the tie.
    /// `incline` is the word that narrows 873 exercises down; `press` and
    /// `barbell` are in a hundred names each and narrow almost nothing. The
    /// term that carries the most information should decide the order.
    ///
    /// Clamped at both ends. A term the catalog has never seen is usually a
    /// typo rather than a maximally precise word, and letting it dominate would
    /// let one mistyped letter bury the lift the lifter is looking for.
    func weight(for term: String) -> Double {
        let frequency = documentFrequency[term] ?? 0
        let idf = log(Double(entries.count + 1) / Double(frequency + 1))
        return min(max(idf, 0.4), 3.0)
    }

    /// Every exercise scoring at or above the cutoff, best first.
    ///
    /// An empty query returns nothing rather than everything — "no search" is
    /// the caller's state to handle, and it's the one case where the caller's
    /// own ordering (how much the lifter uses each lift) should win outright.
    public func ranked(_ query: String) -> [ScoredExercise] {
        let terms = ExerciseSearchText.queryTokens(query)
        guard !terms.isEmpty else { return [] }

        // Computed once for the query rather than per entry.
        let weights = terms.map(weight(for:))

        var results: [ScoredExercise] = []
        for entry in entries {
            let score = score(terms, weights, entry)
            if score >= ExerciseSearch.cutoff {
                results.append(ScoredExercise(exercise: entry.exercise, score: score))
            }
        }
        // Score first; the caller breaks ties on usage, which it knows and this
        // doesn't. Name last so the order is stable rather than arbitrary.
        results.sort {
            $0.score == $1.score
                ? $0.exercise.name.localizedCompare($1.exercise.name) == .orderedAscending
                : $0.score > $1.score
        }
        return results
    }

    /// Weighted mean of each query term's best match, penalized for name
    /// tokens the query didn't account for.
    ///
    /// Returns 0 for anything that can't reach the cutoff, which the caller
    /// filters out anyway.
    ///
    /// **Mean, not sum**, so a two-word query isn't automatically beaten by a
    /// one-word query that happens to match perfectly — every term has to pull
    /// its weight, and `weight(for:)` decides how much that weight is.
    ///
    /// **The penalty** is what puts *Barbell Squat* above *Barbell Hack Squat*
    /// for "barbell squat": both match every term, but one is entirely
    /// accounted for by the query and the other has a word the lifter didn't
    /// ask for. Small, so it orders equals rather than overriding a genuinely
    /// better term match.
    func score(_ terms: [String], _ weights: [Double], _ entry: Entry) -> Double {
        guard !terms.isEmpty else { return 0 }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return 0 }
        let penalty = 0.01 * Double(max(0, entry.name.count - terms.count))
        var accumulated = 0.0
        var spent = 0.0
        for (position, term) in terms.enumerated() {
            accumulated += weights[position] * Self.bestMatch(term, entry)
            spent += weights[position]
            // Abandon as soon as a perfect score on every remaining term
            // couldn't clear the cutoff. Because the score is a weighted mean,
            // one unanswered heavy term already makes most entries
            // unreachable — which is where the time goes on a typed query.
            let best = (accumulated + (totalWeight - spent)) / totalWeight - penalty
            if best < ExerciseSearch.cutoff { return 0 }
        }
        return accumulated / totalWeight - penalty
    }

    private static func bestMatch(_ term: String, _ entry: Entry) -> Double {
        var best = 0.0
        for token in entry.name {
            if token == term { return 1.0 }
            switch prefixMatch(token, term) {
            case .typedPrefix: best = max(best, 0.85)
            case .containsToken: best = max(best, 0.7)
            case .none: break
            }
        }
        // The fuzzy tier is the expensive one, and it only has a job when the
        // term matched no name token at all — which is exactly the typo case.
        // Skipping it whenever anything did match takes the edit distances out
        // of the common path entirely, and typing is the common path.
        if best == 0 {
            for token in entry.name {
                if let ratio = ExerciseSearchText.similarity(term, token) {
                    best = max(best, 0.6 * ratio)
                }
            }
        }
        // Metadata only gets consulted when the name didn't answer well.
        if best < 0.85 {
            for token in entry.meta {
                if token == term {
                    best = max(best, 0.6)
                } else if prefixMatch(token, term) != .none {
                    best = max(best, 0.45)
                }
            }
        }
        return best
    }

    /// How a term relates to a token when neither is the other exactly.
    ///
    /// Both directions count, and they don't count the same. Typing a prefix of
    /// a longer word is search-as-you-type and is what a lifter is usually
    /// doing — "incl" on the way to *incline*. The other direction, where the
    /// catalog's word is a prefix of what was typed, is how "butterfly" reaches
    /// *Butt-Ups*: real often enough to be worth keeping (dropping it cost a
    /// point of recall and put a query back on a blank screen), and weak enough
    /// that it belongs below everything else rather than beside it.
    ///
    /// Floored at three characters in both directions: below that a prefix is
    /// noise, and "ab" would match *abductor*, *abdominal* and *ab roller*
    /// equally while the lifter meant one of them.
    private enum PrefixMatch {
        case none
        /// The lifter typed the start of the catalog's word.
        case typedPrefix
        /// The catalog's word is the start of what the lifter typed.
        case containsToken
    }

    private static func prefixMatch(_ token: String, _ term: String) -> PrefixMatch {
        guard term.count >= 3 else { return .none }
        if token.hasPrefix(term) { return .typedPrefix }
        guard token.count >= 3, term.hasPrefix(token) else { return .none }
        return .containsToken
    }
}

/// An exercise and how well it matched.
public struct ScoredExercise: Hashable, Sendable {
    public let exercise: Exercise
    public let score: Double

    public init(exercise: Exercise, score: Double) {
        self.exercise = exercise
        self.score = score
    }
}

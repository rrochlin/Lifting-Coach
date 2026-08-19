import Foundation

/// Turning a lift's name — typed or catalogued — into comparable tokens.
///
/// The same pipeline runs over both sides, which is the point: `pushups` in the
/// catalog and `push up` in the search field have to arrive at the same tokens,
/// and that only holds if neither side is special-cased.
enum ExerciseSearchText {

    // MARK: - Tokenizing

    /// Catalog text → tokens. Lowercased, stripped of punctuation and
    /// diacritics, then spelled out, split and stemmed word by word.
    static func tokens(_ text: String) -> [String] {
        finish(spellOut(normalized(text)))
    }

    /// Query text → tokens. Identical, except that authored aliases get a pass
    /// over the whole string in the middle.
    ///
    /// **Aliases run first, on the text as typed.** They're phrases, so they
    /// can't be applied one word at a time — and running them before the
    /// abbreviation pass is what keeps the two tables from shadowing each
    /// other: expanding `pec` to `chest` first would leave `pec deck` as
    /// `chest deck`, which no alias key matches and no catalog entry contains.
    /// The consequence is that every abbreviation has to expand straight into
    /// the catalog's own vocabulary (`ohp` → `shoulder press`, not `overhead
    /// press`), since nothing translates it afterwards.
    static func queryTokens(_ text: String) -> [String] {
        finish(spellOut(applyAliases(normalized(text))))
    }

    /// Lowercase, fold diacritics, and reduce anything that isn't a letter or
    /// an ASCII digit to a space. Hyphens and parentheses are separators here,
    /// which is what makes "Barbell Bench Press - Medium Grip" and "Bench Press
    /// (Barbell)" tokenize into comparable words.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = true
        for character in folded {
            // ASCII digits only: `Character.isNumber` is also true of things
            // like ¾, which is punctuation as far as a lift's name goes.
            if character.isLetter || (character.isNumber && character.isASCII) {
                out.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Expands abbreviations in place, leaving a normalized string. Separate
    /// from tokenizing because an abbreviation can become several words and the
    /// alias pass in between works on phrases.
    private static func spellOut(_ normalized: String) -> String {
        normalized.split(separator: " ")
            .map { abbreviations[String($0)] ?? String($0) }
            .joined(separator: " ")
    }

    /// Normalized, spelled-out text → the tokens it contributes.
    private static func finish(_ text: String) -> [String] {
        text.split(separator: " ").flatMap { word -> [String] in
            let word = String(word)
            if stopWords.contains(word) { return [] }
            let stemmed = stem(word)
            // Compound splitting after stemming, so "pushups" → "pushup" →
            // ["push", "up"] rather than missing the table by a plural.
            if let split = compounds[stemmed] {
                return split.split(separator: " ").map(String.init)
            }
            return [stemmed]
        }
    }

    // MARK: - Stemming

    /// Strips plurals, and **only** plurals.
    ///
    /// Deliberately not a Porter stemmer: this has to be *idempotent*, because
    /// it runs over the query and the catalog independently and their tokens
    /// have to land in the same place. Porter is not — it would take `press` to
    /// `pres` while taking `presses` to `press`, so the two would never meet.
    /// Every rule below leaves its own output alone.
    static func stem(_ word: String) -> String {
        // Three letters is enough to be a plural — "ups" has to reach "up"
        // for `pull ups` to meet `Pullups`.
        guard word.count > 2 else { return word }
        if word.hasSuffix("ies"), word.count > 4 {
            return String(word.dropLast(3)) + "y"          // flies → fly
        }
        if word.hasSuffix("sses") {
            return String(word.dropLast(2))                // presses → press
        }
        for suffix in ["ches", "shes", "xes", "zes"] where word.hasSuffix(suffix) {
            return String(word.dropLast(2))                // crunches → crunch
        }
        // `ss` is not a plural (press, cross); `us` usually isn't either.
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") {
            return String(word.dropLast())                 // squats → squat
        }
        return word
    }

    // MARK: - Similarity

    /// How alike two tokens are, or `nil` when they aren't alike enough to be
    /// worth reporting.
    ///
    /// Guarded on both sides before any distance is computed: short words are
    /// excluded because at four characters an edit is a different word (`curl`
    /// and `curb`), and a length gap above two can't reach the threshold
    /// anyway. Those two guards are what keep this off the hot path for most
    /// comparisons.
    static func similarity(_ a: String, _ b: String) -> Double? {
        let (countA, countB) = (a.count, b.count)
        guard countA >= 5, countB >= 5, abs(countA - countB) <= 2 else { return nil }
        let longest = max(countA, countB)
        // ratio ≥ 0.8 ⇒ distance ≤ 0.2 × longest. Computing past that is wasted.
        let budget = Int(Double(longest) * 0.2)
        guard budget > 0, let distance = editDistance(a, b, budget: budget) else { return nil }
        return 1.0 - Double(distance) / Double(longest)
    }

    /// Levenshtein distance, abandoning as soon as every path exceeds `budget`.
    static func editDistance(_ a: String, _ b: String, budget: Int) -> Int? {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...y.count {
                let substitution = previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowBest = min(rowBest, current[j])
            }
            if rowBest > budget { return nil }
            swap(&previous, &current)
        }
        let distance = previous[y.count]
        return distance <= budget ? distance : nil
    }

    // MARK: - Vocabulary

    /// Words that carry no signal in a lift's name.
    static let stopWords: Set<String> = ["the", "a", "an", "of", "with", "and", "to", "for"]

    /// What lifters type instead of what the catalog writes.
    ///
    /// Applied to **both** sides, so the mapping only has to be right in one
    /// direction: `triceps` and `tricep` meet because the stemmer takes both to
    /// `tricep`, and `abs` meets `abdominals` because this maps the first to
    /// `abdominal` and the stemmer takes the second there too.
    static let abbreviations: [String: String] = [
        "bb": "barbell",
        "db": "dumbbell",
        "kb": "kettlebell",
        // The catalog says "shoulder press" and never once says "overhead
        // press", and nothing translates an abbreviation after this point.
        "ohp": "shoulder press",
        "dl": "deadlift",
        "rdl": "romanian deadlift",
        "sldl": "stiff leg deadlift",
        "gm": "good morning",
        "abs": "abdominal",
        "ab": "abdominal",
        "pec": "chest",
        "calf": "calve",
        "quad": "quadricep",
        "ham": "hamstring",
        "delt": "deltoid",
    ]

    /// Words written both ways in the wild. Split so the halves match either
    /// spelling — `pushup` and `push up` both become `["push", "up"]`.
    static let compounds: [String: String] = [
        "pushup": "push up",
        "pullup": "pull up",
        "chinup": "chin up",
        "situp": "sit up",
        "stepup": "step up",
        "pushdown": "push down",
        "pulldown": "pull down",
        "crossover": "cross over",
        "rollout": "roll out",
        "lockout": "lock out",
        "flye": "fly",
        "kickback": "kick back",
    ]

    // MARK: - Aliases

    /// Gym vocabulary the vendored catalog has no word for.
    ///
    /// **This is the one authored table in the search, and it earns its place:**
    /// against the 130-query benchmark it takes recall from 87% to 99%. The
    /// residual failures it fixes are not spelling problems — no amount of
    /// fuzziness gets from "Pec Deck" to *Butterfly*, and the on-device
    /// embeddings that are supposed to solve exactly this ranked that pair 851st
    /// of 873 (see `ExerciseSearch`).
    ///
    /// It is judgment recorded once by a person, in the open, reviewable — the
    /// same pattern as `Resources/Block1.json` and
    /// `scripts/data/strong_exercise_map.json`. It is **not** the name matching
    /// `Concepts.md` forbids: it proposes ranked candidates into a picker where
    /// a lifter chooses, and decides nothing about what any exercise *is*.
    ///
    /// Every phrase here was verified to name something the catalog actually
    /// has — `overhead press` is the standout, since the catalog says
    /// *shoulder press* and never once says *overhead press*. Applied
    /// longest-first so a longer phrase wins over a shorter one inside it.
    static let aliases: [String: String] = [
        "overhead press": "shoulder press",
        "military press": "shoulder press",
        "pec deck": "butterfly",
        "pec fly": "butterfly",
        "chest fly cable": "cable crossover",
        "cable chest fly": "cable crossover",
        "cable fly": "cable crossover",
        "reverse fly": "rear delt fly",
        "toes to bar": "hanging leg raise",
        "knees to elbows": "hanging leg raise",
        "nordic leg curl": "natural glute ham raise",
        "nordic curl": "natural glute ham raise",
        "nordic": "glute ham raise",
        "hip abductor": "thigh abductor",
        "hip adductor": "thigh adductor",
        "bicycle crunch": "air bike",
        "ab wheel": "abdominal roller",
        "plate loaded": "leverage",
        "iso lateral": "leverage",
        "french press": "triceps extension",
        "skull crusher": "lying triceps press",
        "stationary bike": "bicycling stationary",
        "exercise bike": "bicycling stationary",
    ]

    /// Alias keys, longest first, so "nordic leg curl" is consumed before
    /// "nordic" can claim part of it.
    private static let aliasKeys: [String] = aliases.keys.sorted {
        $0.count == $1.count ? $0 < $1 : $0.count > $1.count
    }

    static func applyAliases(_ normalizedQuery: String) -> String {
        var query = normalizedQuery
        for key in aliasKeys where query.contains(key) {
            guard let replacement = aliases[key] else { continue }
            query = query.replacingOccurrences(of: key, with: replacement)
        }
        return query
    }
}

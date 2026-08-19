import Foundation

/// Which of the lifter's maxes a percentage prescription resolves against.
///
/// "80%" is unresolvable until you know 80% of *which* number — the three kinds
/// of max are distinct data points and never interchangeable (Core Tenets §6).
public enum MaxReference: String, Codable, Hashable, Sendable {
    /// Actually lifted, verified, date-stamped — the only one that is a fact.
    case achieved
    /// What the program is written against; aspirational by construction. A plan
    /// built on goal maxes is intentional, not an error to correct.
    case goal
    /// Estimated from logged work; derived on demand, never stored. Until the
    /// estimation model exists, a `.theoretical` reference simply doesn't
    /// resolve and the set's weight stays blank.
    case theoretical
}

/// What to put on the bar. Resolved to an absolute weight when the plan becomes
/// a live `Workout`; a percentage that can't be resolved stays unresolved rather
/// than guessing a number (Core Tenets §10).
public enum LoadPrescription: Codable, Hashable, Sendable {
    case absolute(Measurement<UnitMass>)
    case percentOf(Double, of: MaxReference)

    /// Resolves against the referenced max, rounding to the plate increment for
    /// the max's unit (5 lb / 2.5 kg) — the same resolution the source
    /// spreadsheet performs with `MROUND(max*pct, 5)`. Returns `nil` when the
    /// referenced max isn't available; the prescription then displays as-is.
    public func resolvedWeight(
        against max: (MaxReference) -> Measurement<UnitMass>?
    ) -> Measurement<UnitMass>? {
        switch self {
        case .absolute(let weight):
            return weight
        case .percentOf(let percent, let reference):
            guard let max = max(reference) else { return nil }
            let raw = max.value * percent
            let increment = max.unit == .pounds ? 5.0 : 2.5
            return Measurement(value: (raw / increment).rounded() * increment, unit: max.unit)
        }
    }

    /// The prescription as the plan wrote it — what the UI shows beside (or
    /// instead of) a resolved weight.
    public var prescriptionDescription: String {
        switch self {
        case .absolute(let weight):
            let number = weight.value.formatted(.number.precision(.fractionLength(0...2)))
            return "\(number) \(weight.unit.symbol)"
        case .percentOf(let percent, let reference):
            return "\(Int((percent * 100).rounded()))% \(reference.rawValue)"
        }
    }
}

/// How hard a set should feel. RPE on the app's 1–10 scale (0.5 increments,
/// anchored 6–10) — exertion, **not** reps in reserve; RIR appears nowhere in
/// this app (Core Tenets §3).
///
/// No consumer adjusts a prescription against this automatically. Modality —
/// ceiling, target, to-failure, dual progression — is the plan's business,
/// carried in notes and interpreted by the lifter (Core Tenets §1, §4).
public struct EffortTarget: Codable, Hashable, Sendable {
    public var rpe: Float

    public init(rpe: Float) {
        self.rpe = rpe
    }

    /// The anchored descriptor, or `nil` below the programming band — the UI
    /// shows an unanchored value as a bare number rather than inventing a label.
    public var descriptor: String? {
        switch rpe {
        case 10...: "failure"
        case 9..<10: "all-out effort"
        case 8..<9: "exertion"
        case 7..<8: "some effort"
        case 6..<7: "easy"
        default: nil
        }
    }
}

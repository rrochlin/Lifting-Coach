import Foundation

extension Measurement where UnitType == UnitMass {
    /// A barbell weight as a lifter would read it: `"157.5 lb"`, `"268 lb"`.
    ///
    /// Deliberately *not* `.measurement(usage: .personWeight)`, which rounds to
    /// whole units. Plates come in 2.5 lb / 1.25 kg increments, so 157.5 lb is a
    /// weight you can actually load — rounding it to 158 shows a number that
    /// can't exist on a bar and misreports what was lifted. `.personWeight` is
    /// for bodyweight, where whole units are fine.
    var liftedDescription: String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        return "\(number) \(unit.symbol)"
    }
}

extension Float {
    /// RPE to one decimal at most: `"8"`, `"8.5"`.
    var rpeDescription: String {
        formatted(.number.precision(.fractionLength(0...1)))
    }
}

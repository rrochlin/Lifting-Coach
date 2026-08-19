import Foundation

/// The unit a lifter reads and enters weights in.
///
/// Deliberately two cases rather than all of `UnitMass`. Grams, ounces and
/// stones are real units and none of them is a plausible answer to "what do you
/// load your bar in" — a two-case enum makes the switcher exhaustive and makes
/// `Codable` conformance trivial, which a bare `UnitMass` (NSCoding, not
/// Codable) does not have.
///
/// The raw values are the same symbols `Measurement` writes to SQLite, so a
/// preference and a stored weight's unit column speak the same language.
public enum WeightUnit: String, Codable, Hashable, Sendable, CaseIterable {
    case pounds = "lb"
    case kilograms = "kg"

    public var unit: UnitMass {
        switch self {
        case .pounds: .pounds
        case .kilograms: .kilograms
        }
    }

    public var symbol: String { rawValue }

    /// `nil` for any unit outside the two — a stored weight in grams is data to
    /// be converted, never a display preference to adopt.
    public init?(_ unit: UnitMass) {
        switch unit.symbol {
        case UnitMass.pounds.symbol: self = .pounds
        case UnitMass.kilograms.symbol: self = .kilograms
        default: return nil
        }
    }
}

extension Measurement where UnitType == UnitMass {
    /// The same weight, expressed in the lifter's unit.
    ///
    /// Storage stays faithful to whatever unit a weight was entered in — a set
    /// logged at 225 lb is still 225 lb on disk after the lifter switches to
    /// kg. What the preference governs is *reading*: the number on screen is
    /// this weight in the unit they asked to see it in.
    ///
    /// A converted weight rounds to a tenth; a weight already in the right unit
    /// is returned untouched.
    ///
    /// The untouched case matters most: 157.5 lb read in pounds is exactly what
    /// the lifter typed, and rounding it would be the app editing their log.
    ///
    /// Conversions round because the extra digits are noise, not information.
    /// 225 lb is 102.05828 kg, and a tracker field showing that would write the
    /// drift back on the first edit while the Home readout wrapped onto two
    /// lines to display digits nobody can load. A tenth of a kilo is more than
    /// ten times finer than the smallest plate on any bar.
    public func expressed(in weightUnit: WeightUnit) -> Measurement<UnitMass> {
        guard unit.symbol != weightUnit.symbol else { return self }
        let value = converted(to: weightUnit.unit).value
        return Measurement(value: (value * 10).rounded() / 10, unit: weightUnit.unit)
    }
}

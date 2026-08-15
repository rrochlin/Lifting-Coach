import Foundation

/// Rebuilds a weight from a stored value and unit symbol.
///
/// Weights are persisted with the unit they were entered in rather than
/// normalized to kilograms, so 185 lb reads back as 185 lb instead of an
/// 83.9-ish decimal that never matches what was actually on the bar.
func measurement(value: Double, symbol: String?) -> Measurement<UnitMass> {
    guard let symbol else { return Measurement(value: value, unit: .kilograms) }

    let unit: UnitMass = switch symbol {
    case UnitMass.pounds.symbol: .pounds
    case UnitMass.kilograms.symbol: .kilograms
    case UnitMass.grams.symbol: .grams
    case UnitMass.ounces.symbol: .ounces
    case UnitMass.stones.symbol: .stones
    // An unrecognized symbol still round-trips as itself; it just won't convert.
    default: UnitMass(symbol: symbol)
    }
    return Measurement(value: value, unit: unit)
}

/// Optional-passthrough variant. Distinctly named because an overload taking
/// `Double?` is ambiguous against the one above at every call site.
func optionalMeasurement(value: Double?, symbol: String?) -> Measurement<UnitMass>? {
    guard let value else { return nil }
    return measurement(value: value, symbol: symbol)
}

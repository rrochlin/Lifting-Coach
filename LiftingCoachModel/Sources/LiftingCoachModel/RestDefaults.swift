import Foundation

/// The app's fallback rest, per kind of set.
///
/// The bottom of the rest chain — `WorkoutSet.restOverride`, then the
/// prescription in `plannedFrom`, then the block's `defaultRestTimes`, then
/// this. Every level above it is authored by someone (a lifter, a coach); this
/// is the one the app supplies when nobody has said anything.
///
/// **It is per-type because a warmup is not a working set.** A single number
/// meant a ramp-up single and a heavy triple both proposed two minutes, which
/// is wrong in the direction that costs the most: nobody rests two minutes
/// between 45 and 95, so the number under every warmup was one to ignore, and a
/// timer you learn to ignore is worse than no timer.
///
/// A block can still override any of these (`WorkoutBlock.defaultRestTimes`,
/// editable in Block Settings), and a set can override the block. This only
/// decides what happens before anyone bothers.
public struct RestDefaults: Equatable, Hashable, Sendable {
    public var warmup: Int
    public var working: Int
    public var drop: Int

    public init(warmup: Int = 60, working: Int = 120, drop: Int = 60) {
        self.warmup = warmup
        self.working = working
        self.drop = drop
    }

    /// Warmups are short because they're a ramp, not a set; drops are short
    /// because being short is the point of a drop set.
    public static let standard = RestDefaults()

    /// An untyped set is a working set, the same assumption every other rest
    /// lookup in the app makes.
    public subscript(type: SetType?) -> Int {
        switch type ?? .working {
        case .warmup: warmup
        case .working: working
        case .drop: drop
        }
    }
}

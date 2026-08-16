import SwiftUI

/// The app's visual language.
///
/// Dark-first and, for now, dark-only — the whole palette is built for a deep
/// ground, and a light variant would need its own accent work rather than an
/// inversion. `LiftingCoachApp` pins the color scheme accordingly.
///
/// Reference points: the cool blue-black and thin technical overlays of *Ghost
/// in the Shell*, the graphic amber accents of *Cowboy Bebop*, the phosphor
/// glow of *The Matrix*. The restraint matters more than the neon — one accent
/// carries interaction, amber marks the live moment, and everything else stays
/// quiet so the numbers read.
enum Theme {

    // MARK: Ground

    /// App background. Blue-black rather than true black, so panels above it
    /// read as lit rather than as holes.
    static let void = Color(red: 0.039, green: 0.051, blue: 0.067)
    /// Standard panel.
    static let panel = Color(red: 0.071, green: 0.094, blue: 0.129)
    /// Panel that sits above another panel.
    static let panelRaised = Color(red: 0.094, green: 0.125, blue: 0.169)
    /// Hairline rules and panel edges. Cool, low-contrast — structure you feel
    /// more than see.
    static let hairline = Color(red: 0.145, green: 0.188, blue: 0.251)

    // MARK: Ink

    static let ink = Color(red: 0.890, green: 0.925, blue: 0.949)
    static let inkMuted = Color(red: 0.518, green: 0.592, blue: 0.671)
    static let inkFaint = Color(red: 0.353, green: 0.420, blue: 0.494)

    // MARK: Signal

    /// The single interactive accent: HUD cyan. Completion, links, focus.
    static let signal = Color(red: 0.275, green: 0.835, blue: 0.878)
    /// Dimmed signal for fills and glows.
    static let signalDim = Color(red: 0.165, green: 0.541, blue: 0.576)
    /// The live moment — an in-progress set, a running rest timer. Amber earns
    /// its loudness by being rare.
    static let live = Color(red: 0.941, green: 0.651, blue: 0.235)
    /// Destructive and error states.
    static let alert = Color(red: 0.902, green: 0.396, blue: 0.373)

    // MARK: Type

    /// Data, labels, and anything a lifter reads as a number. Monospaced keeps
    /// weights and reps in columns as they change.
    static func data(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Uppercase micro-labels — the HUD annotation layer.
    static let label = Font.system(size: 10, weight: .semibold, design: .monospaced)

    static let title = Font.system(size: 26, weight: .bold, design: .default)
    static let heading = Font.system(size: 16, weight: .semibold, design: .default)
    static let body = Font.system(size: 15, weight: .regular, design: .default)
    static let caption = Font.system(size: 12, weight: .regular, design: .default)
}

// MARK: - Building blocks

/// A bordered panel. The app's one container shape.
struct Panel<Content: View>: View {
    var accent: Color = Theme.hairline
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(accent, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Uppercase, letter-spaced section marker with a rule running off to the edge.
/// The rule is the "readout" cue that ties the screens together.
struct SectionLabel: View {
    let text: String
    var accent: Color = Theme.inkFaint

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(Theme.label)
                .tracking(1.6)
                .foregroundStyle(accent)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }
}

/// A labelled value — the HUD's basic unit.
struct Readout: View {
    let label: String
    let value: String
    var accent: Color = Theme.ink
    var size: CGFloat = 15

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(Theme.inkMuted)
            Spacer(minLength: 12)
            Text(value)
                .font(Theme.data(size, weight: .medium))
                .foregroundStyle(accent)
        }
    }
}

/// Small uppercase status chip.
struct Chip: View {
    let text: String
    var color: Color = Theme.signal

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color.opacity(0.5), lineWidth: 1)
            )
    }
}

// MARK: - Screen chrome

extension View {
    /// Standard screen treatment: themed ground, no default list chrome.
    func screenGround() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.void)
    }

    /// Removes a `List` row's default background and insets so `Panel` can own
    /// the visual container instead of fighting the system's.
    func panelRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }
}

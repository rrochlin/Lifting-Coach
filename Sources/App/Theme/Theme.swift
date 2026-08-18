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
    /// The edge of an editable field. Brighter than `hairline` on purpose: a
    /// structural rule can afford to be felt rather than seen, but the outline
    /// that says "you can change this number" has to be seen, in a gym, at
    /// arm's length, mid-set.
    static let fieldEdge = Color(red: 0.243, green: 0.318, blue: 0.412)

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
    static let label = Font.system(size: 12, weight: .semibold, design: .monospaced)

    static let title = Font.system(size: 26, weight: .bold, design: .default)
    static let heading = Font.system(size: 16, weight: .semibold, design: .default)
    static let body = Font.system(size: 15, weight: .regular, design: .default)
    static let caption = Font.system(size: 14, weight: .regular, design: .default)
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
                // The label takes what it needs and the rule takes the rest.
                // Both are flexible otherwise, so the HStack splits the width
                // between them and a longer label ("MAXES · ACHIEVED / GOAL")
                // wraps onto two lines with the rule floating beside the first
                // — which stopped being hypothetical when the type got bigger.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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

/// The "you can change this" cue: a small caret on a value that opens a picker.
///
/// Strong and Hevy both mark a tappable value this way, and it's the difference
/// between a number that reads as a readout and one that reads as a control.
/// Every quantity in a set row was previously drawn as a quiet filled rectangle
/// with no edge and no caret, which made an editable RPE look exactly like the
/// static annotation text beside it.
struct FieldCaret: View {
    var color: Color = Theme.inkFaint

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
    }
}

extension View {
    /// Draws a value as an editable field: filled, outlined, and tall enough to
    /// hit with a thumb mid-set.
    ///
    /// The one shared look for every quantity a lifter can change — reps,
    /// weight, RPE, rest — so that "this is a control" is a single visual fact
    /// rather than something each screen re-decides. 30pt is short of Apple's
    /// 44pt guidance and deliberately so: a set row carries five of these
    /// side by side at 375pt, and the fields sit inside a row whose own
    /// padding carries the rest of the target.
    ///
    /// `isActive` brightens the edge for a value the lifter set themselves, so
    /// an inherited default and a deliberate choice don't look identical.
    func editableField(isActive: Bool = false, accent: Color = Theme.fieldEdge) -> some View {
        self
            .padding(.horizontal, 7)
            .frame(minHeight: 30)
            .background(Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isActive ? accent : Theme.fieldEdge, lineWidth: 1)
            )
    }
}

// MARK: - Grouped rows

/// Which edges/corners a row draws when several contiguous `List` rows are
/// meant to read as one panel (an exercise header + its set rows, each now a
/// real row of its own so per-set swipe actions actually apply to that set —
/// see `WorkoutTrackerView`).
enum PanelRowPosition {
    case top, middle, bottom, single
}

extension View {
    /// Styles one row as part of a multi-row panel group. `position` controls
    /// which corners round and how much vertical gap surrounds the row, so a
    /// header row plus several set rows read as one continuous block instead of
    /// N separate floating panels.
    ///
    /// Grouped rows use a thin leading accent rail rather than `Panel`'s full
    /// border — a full stroke on every contiguous row would double the line at
    /// each seam between rows in the same group. The rail also reads as a
    /// status indicator (active exercise, superset membership), which suits a
    /// HUD better than a border would anyway.
    func panelGroupRow(_ position: PanelRowPosition, accent: Color = Theme.hairline) -> some View {
        let radius: CGFloat = 6
        let corners: RectangleCornerRadii
        switch position {
        case .single:
            corners = RectangleCornerRadii(
                topLeading: radius, bottomLeading: radius,
                bottomTrailing: radius, topTrailing: radius
            )
        case .top:
            corners = RectangleCornerRadii(topLeading: radius, topTrailing: radius)
        case .middle:
            corners = RectangleCornerRadii()
        case .bottom:
            corners = RectangleCornerRadii(bottomLeading: radius, bottomTrailing: radius)
        }

        return self
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .overlay(alignment: .leading) {
                Rectangle().fill(accent).frame(width: 2)
            }
            .clipShape(UnevenRoundedRectangle(cornerRadii: corners, style: .continuous))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // Zero vertical inset between rows of the same group so the shared
            // background reads continuous; the gap goes outside the group.
            .listRowInsets(EdgeInsets(
                top: position == .top || position == .single ? 6 : 0,
                leading: 16,
                bottom: position == .bottom || position == .single ? 6 : 0,
                trailing: 16
            ))
            .listRowSpacing(0)
    }
}

// MARK: - Themed confirmation

/// Replacement for the system `.confirmationDialog`, in the app's own HUD
/// language rather than a bare system sheet.
struct ThemedConfirmDialog: View {
    let title: String
    var message: String?
    var confirmLabel: String = "Confirm"
    var confirmRole: ButtonRole? = .destructive
    var cancelLabel: String = "Cancel"
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Theme.void.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            Panel(accent: confirmRole == .destructive ? Theme.alert.opacity(0.5) : Theme.hairline) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title.uppercased())
                        .font(Theme.heading)
                        .foregroundStyle(Theme.ink)
                    if let message {
                        Text(message)
                            .font(Theme.body)
                            .foregroundStyle(Theme.inkMuted)
                    }
                    HStack {
                        Button(cancelLabel, action: onCancel)
                            .foregroundStyle(Theme.inkMuted)
                        Spacer()
                        Button(confirmLabel, action: onConfirm)
                            .foregroundStyle(confirmRole == .destructive ? Theme.alert : Theme.signal)
                    }
                    .font(Theme.label)
                    .tracking(1.2)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 32)
        }
    }
}

extension View {
    /// Presents a `ThemedConfirmDialog` as an overlay when `isPresented` is
    /// true — the themed stand-in for `.confirmationDialog`.
    func themedConfirm(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        confirmLabel: String = "Confirm",
        confirmRole: ButtonRole? = .destructive,
        cancelLabel: String = "Cancel",
        onConfirm: @escaping () -> Void
    ) -> some View {
        overlay {
            if isPresented.wrappedValue {
                ThemedConfirmDialog(
                    title: title,
                    message: message,
                    confirmLabel: confirmLabel,
                    confirmRole: confirmRole,
                    cancelLabel: cancelLabel,
                    onConfirm: {
                        isPresented.wrappedValue = false
                        onConfirm()
                    },
                    onCancel: { isPresented.wrappedValue = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isPresented.wrappedValue)
    }
}

// MARK: - Screen chrome

extension View {
    /// Standard screen treatment: themed ground, no default list chrome, and a
    /// keyboard that gets out of the way when the lifter scrolls past it.
    ///
    /// A decimal pad has no return key, so `NumberField` puts a DONE above it —
    /// but dragging the list is the other thing a lifter does with a keyboard
    /// on screen, and it should mean the same thing. Applied here rather than
    /// per screen because every scrolling surface in the app already wears this
    /// modifier, and one that forgot it would be the one that traps you.
    func screenGround() -> some View {
        self
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
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

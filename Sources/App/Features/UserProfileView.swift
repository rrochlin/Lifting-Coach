import SwiftUI
import LiftingCoachModel

/// Account management and service connections, per `Features/User Profile.md`.
///
/// Most of this page is inherently phase 2 — sign in/out and SSO need Cognito.
/// Data export/import is the one part that's local-only and buildable now, and
/// `Ideas.md` calls importing from other apps out as crucial.
///
/// It's also where the app's one real setting lives: the unit weights are read
/// in. This screen was still wearing default iOS chrome while every other tab
/// was themed; adding a control the lifter is meant to *find* was the point at
/// which that stopped being acceptable.
struct UserProfileView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            List {
                unitsSection
                accountSection
                dataSection
            }
            .listStyle(.plain)
            .screenGround()
            .navigationTitle("Profile")
        }
    }

    @ViewBuilder
    private var unitsSection: some View {
        SectionLabel(text: "units", accent: Theme.signal).panelRow()

        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(WeightUnit.allCases, id: \.self) { unit in
                        unitButton(unit)
                    }
                }
                // Says what switching does and, more importantly, what it
                // doesn't. A lifter who thinks the button rewrites their log
                // won't press it.
                Text("Changes how weights are shown and entered. Nothing already logged is rewritten — a set logged in lb stays a lb entry on disk.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .panelRow()
    }

    private func unitButton(_ unit: WeightUnit) -> some View {
        let selected = environment.weightUnit == unit
        return Button {
            environment.setWeightUnit(unit)
        } label: {
            VStack(spacing: 2) {
                Text(unit.symbol.uppercased())
                    .font(Theme.data(17, weight: selected ? .semibold : .regular))
                Text(unit == .pounds ? "pounds" : "kilograms")
                    .font(Theme.label)
                    .tracking(1.1)
            }
            .foregroundStyle(selected ? Theme.void : Theme.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? Theme.signal : Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? Theme.signal : Theme.fieldEdge, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var accountSection: some View {
        SectionLabel(text: "account").panelRow()

        Panel {
            VStack(alignment: .leading, spacing: 9) {
                Readout(
                    label: "status",
                    value: environment.backend.isAvailable ? "Signed in" : "Local only",
                    accent: environment.backend.isAvailable ? Theme.ink : Theme.inkMuted
                )
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("Sign in, SSO, and account deletion need the phase 2 backend.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .panelRow()
    }

    @ViewBuilder
    private var dataSection: some View {
        SectionLabel(text: "data", accent: Theme.inkFaint).panelRow()

        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("NOT STARTED")
                    .font(Theme.label)
                    .tracking(1.4)
                    .foregroundStyle(Theme.inkFaint)
                Text("Export and import are local-only and buildable in phase 1.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .panelRow()
    }
}

#Preview {
    UserProfileView()
        .environment(AppEnvironment.preview())
}

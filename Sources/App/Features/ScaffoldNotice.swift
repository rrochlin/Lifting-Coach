import SwiftUI

/// Placeholder body for a screen that exists in navigation but isn't built yet.
///
/// Deliberately blunt rather than a convincing mock: a half-built screen that
/// *looks* finished is harder to reason about than one that says what's missing.
/// Each notice names the feature doc that specifies it.
struct ScaffoldNotice: View {
    let feature: String
    let doc: String
    let requirements: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "not built", accent: Theme.live)

                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(feature)
                            .font(Theme.title)
                            .foregroundStyle(Theme.ink)
                        Text("Specified in \(doc)")
                            .font(Theme.data(13))
                            .foregroundStyle(Theme.inkFaint)

                        if !requirements.isEmpty {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(requirements, id: \.self) { requirement in
                                    HStack(alignment: .top, spacing: 9) {
                                        Text("—")
                                            .font(Theme.data(13))
                                            .foregroundStyle(Theme.signalDim)
                                        Text(requirement)
                                            .font(Theme.caption)
                                            .foregroundStyle(Theme.inkMuted)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .screenGround()
    }
}

#Preview {
    ScaffoldNotice(
        feature: "Workout Tracker",
        doc: "Features/Workout Tracker.md",
        requirements: ["Check off sets as completed", "Highlight the active exercise"]
    )
}

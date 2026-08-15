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
        ContentUnavailableView {
            Label(feature, systemImage: "hammer.fill")
        } description: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Not built yet. Specified in \(doc).")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)

                if !requirements.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(requirements, id: \.self) { requirement in
                            Label(requirement, systemImage: "circle.dashed")
                                .font(.caption)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal)
        }
    }
}

#Preview {
    ScaffoldNotice(
        feature: "Workout Tracker",
        doc: "Features/Workout Tracker.md",
        requirements: ["Check off sets as completed", "Highlight the active exercise"]
    )
}

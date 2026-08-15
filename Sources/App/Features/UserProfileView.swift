import SwiftUI

/// Account management and service connections, per `Features/User Profile.md`.
///
/// Most of this page is inherently phase 2 — sign in/out and SSO need Cognito.
/// Data export/import is the one part that's local-only and buildable now, and
/// `Ideas.md` calls importing from other apps out as crucial.
struct UserProfileView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Status") {
                        Text(environment.backend.isAvailable ? "Signed in" : "Local only")
                            .foregroundStyle(.secondary)
                    }
                    Text("Sign in, SSO, and account deletion need the phase 2 backend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Data") {
                    Text("Export and import are local-only and buildable in phase 1 — not started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Profile")
        }
    }
}

#Preview {
    UserProfileView()
        .environment(AppEnvironment.preview())
}

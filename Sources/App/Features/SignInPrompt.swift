import AuthenticationServices
import SwiftUI

/// Asks at launch whether to back up, when nobody is signed in.
///
/// Before this the only route to sign-in was a button on Profile, so on a first
/// launch nothing said backups existed — and when the thirty-day session
/// lapsed, backups stopped with nothing saying they had. See
/// `AppEnvironment.shouldPromptSignIn` for when this appears.
///
/// It **asks and never gates**: "Keep this phone local" is a full answer, it's
/// remembered, and the app is entirely usable without an account. Signing in
/// still needs one pass through Apple's or Cognito's page — that part can't be
/// made invisible — but after it the session refreshes itself silently.
struct SignInPrompt: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var message: String?

    /// A lapsed session reads differently from a first launch: it isn't an
    /// offer, it's backups having stopped.
    private var wasSignedIn: Bool {
        // Flattened explicitly: `try?` over an optional `map` yields a
        // `String??`, and comparing that to nil reads "never bound" as bound.
        guard let user = environment.currentUser,
              let binding = try? environment.users.accountBinding(for: user.id)
        else { return false }
        return binding != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.signal)

            Text(wasSignedIn ? "Sign in again to keep backing up" : "Back up your training")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(wasSignedIn
                 ? "Your sign-in lasts thirty days, and it has run out. Backups are paused until you sign in again — nothing on this phone is affected."
                 : "Sign in and your log is backed up to the cloud after every workout, so a lost or replaced phone doesn't take your training history with it.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Text("Email and Sign in with Apple are separate accounts — pick one and keep using it.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                signIn()
            } label: {
                Text(isWorking ? "SIGNING IN…" : "SIGN IN")
                    .font(Theme.label).tracking(1.2)
                    .foregroundStyle(Theme.void)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isWorking ? Theme.inkMuted : Theme.signal)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            Button {
                environment.keepsLocal = true
                dismiss()
            } label: {
                Text("KEEP THIS PHONE LOCAL")
                    .font(Theme.label).tracking(1.2)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            Text("You can sign in later from Profile.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.void)
        .interactiveDismissDisabled(isWorking)
    }

    private func signIn() {
        isWorking = true
        message = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await environment.signIn(with: webAuthenticationSession)
                dismiss()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // Backed out of the page; stay here and let them choose again.
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

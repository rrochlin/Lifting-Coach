import AuthenticationServices
import SwiftUI

/// Sign-in at launch, in two forms.
///
/// **Required** on a phone that has never signed in: full screen, nothing to
/// dismiss. Sign-in is part of the app — phase 1 was offline only to keep
/// development simple — and Apple's or Cognito's page needs one pass through
/// it; after that the session refreshes itself silently.
///
/// **Asked, never required** when a session has lapsed (thirty days from
/// sign-in, INFRA-SPEC D3). Blocking there would lock a lifter in a basement
/// gym with no signal out of logging the set in front of them; the log is
/// local, so only the upload has to wait. See `AppEnvironment.requiresSignIn`
/// and `sessionLapsed`.
struct SignInPrompt: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var message: String?

    /// A lapsed session reads differently from a first launch: it isn't the
    /// front door, it's backups having stopped.
    private var isLapse: Bool { environment.sessionLapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.signal)

            Text(isLapse ? "Sign in again to keep backing up" : "Sign in to get started")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(isLapse
                 ? "Your sign-in lasts thirty days, and it has run out. Backups are paused until you sign in again — nothing on this phone is affected."
                 : "Your training log is backed up to the cloud after every workout, so a lost or replaced phone doesn't take your history with it. Sign in once and it stays signed in.")
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

            if isLapse {
                Button {
                    dismiss()
                } label: {
                    Text("LATER")
                        .font(Theme.label).tracking(1.2)
                        .foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                Text("Logging works without signing in. Backups resume when you do.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.void)
        .interactiveDismissDisabled(isWorking || !isLapse)
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

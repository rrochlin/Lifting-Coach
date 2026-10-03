import LiftingCoachCloud
import SwiftUI

/// Sign-in at launch, in two forms.
///
/// **Required** on a phone that has never signed in: full screen, nothing to
/// dismiss. Sign-in is part of the app — phase 1 was offline only to keep
/// development simple — and it is Sign in with Apple, natively: Apple's own
/// button and the system sheet, never a browser (INFRA-SPEC §3.5). One pass
/// through it, and the session refreshes itself silently after that.
///
/// **Asked, never required** when a session has lapsed (thirty days from
/// sign-in, INFRA-SPEC D3). Blocking there would lock a lifter in a basement
/// gym with no signal out of logging the set in front of them; the log is
/// local, so only the upload has to wait. See `AppEnvironment.requiresSignIn`
/// and `sessionLapsed`.
struct SignInPrompt: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var message: String?

    /// A lapsed session reads differently from a first launch: it isn't the
    /// front door, it's backups having stopped.
    private var isLapse: Bool { environment.sessionLapsed }

    /// Centred on both axes, as a sign-in screen conventionally is: one
    /// block — mark, title, a sentence, the button — sitting in the middle of
    /// the screen, so the eye lands on the button without travelling. It was
    /// a top-aligned column with the button pinned to the bottom, which left
    /// the screen's centre empty and read as an unfinished settings page.
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 20) {
                mark

                VStack(spacing: 10) {
                    Text(isLapse ? "Sign in again to keep backing up" : "Sign in to get started")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.ink)

                    Text(isLapse
                         ? "Your sign-in lasts thirty days, and it has run out. Backups are paused until you sign in again — nothing on this phone is affected."
                         : "Your training log is backed up after every workout, so losing your phone never means losing your history.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 12) {
                    if isWorking {
                        // Apple's sheet is done; this is Cognito and the first
                        // backup check. In place of the button, so it can't be
                        // tapped twice, and the same height so nothing jumps.
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.signal)
                            Text("SIGNING IN…").font(Theme.label).tracking(1.2).foregroundStyle(Theme.inkMuted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    } else {
                        AppleSignInButton(label: isLapse ? .continue : .signIn) { apple in
                            signIn(apple)
                        } onError: { error in
                            message = error.localizedDescription
                        }
                    }

                    if let message {
                        Text(message)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.alert)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isLapse {
                        Button {
                            dismiss()
                        } label: {
                            Text("LATER")
                                .font(Theme.label).tracking(1.2)
                                .foregroundStyle(Theme.inkMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                    }
                }
                .padding(.top, 8)
            }
            // A readable measure on a wide phone, and the button no wider than
            // the text above it.
            .frame(maxWidth: 360)

            Spacer(minLength: 24)

            // The reassurance belongs to the screen, not the decision, so it
            // sits at the foot rather than in the block competing with it.
            Text(isLapse
                 ? "Logging works without signing in. Backups resume when you do."
                 : "Your log lives on this phone. The cloud copy is a backup, so logging a set never waits on a connection.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.void)
        .interactiveDismissDisabled(isWorking || !isLapse)
    }

    /// The app's own mark rather than a cloud glyph: this is the front door of
    /// the app, not a backup settings screen.
    private var mark: some View {
        Image(systemName: "dumbbell.fill")
            .font(.system(size: 34, weight: .regular))
            .foregroundStyle(Theme.signal)
            .frame(width: 76, height: 76)
            .background(Circle().fill(Theme.signal.opacity(0.12)))
            .overlay(Circle().strokeBorder(Theme.signal.opacity(0.35), lineWidth: 1))
    }

    private func signIn(_ apple: AppleCredential) {
        isWorking = true
        message = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await environment.signIn(with: apple)
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

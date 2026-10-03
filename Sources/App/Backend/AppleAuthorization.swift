import AuthenticationServices
import LiftingCoachCloud
import SwiftUI
import UIKit

/// Native Sign in with Apple — the system sheet, Face ID, no browser
/// (INFRA-SPEC §3.5).
///
/// Two entry points, because there are two moments. **Signing in** uses
/// `AppleSignInButton`, Apple's own button, since that's what a lifter expects
/// to tap and what the review guidelines ask for. **Confirming a deletion** has
/// no button to tap — it follows a confirmation dialog — so it presents the
/// same sheet directly through `AppleAuthorization.confirm()`.
///
/// Every request carries a fresh nonce: Apple embeds its hash in the token, and
/// the server is sent the original. See `AppleNonce`.
enum AppleAuthorization {
    /// Configures a request the way both entry points need it.
    static func configure(_ request: ASAuthorizationAppleIDRequest, nonce: AppleNonce) {
        // Email only — never the name. The name isn't used anywhere, and
        // Apple only sends it once, which would make it a value that silently
        // goes missing on the second phone.
        request.requestedScopes = [.email]
        request.nonce = nonce.hashed
    }

    static func credential(from authorization: ASAuthorization, nonce: AppleNonce) throws -> AppleCredential {
        guard
            let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
            let token = apple.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
            let code = apple.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) })
        else { throw CloudError.signInRejected("Apple returned no token.") }
        return AppleCredential(identityToken: token, authorizationCode: code, rawNonce: nonce.raw)
    }

    /// Whether an error is the lifter backing out of the sheet, which is not
    /// worth a word on screen.
    static func isCancellation(_ error: any Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }

    /// Presents the sheet without a button and waits for it.
    @MainActor
    static func confirm() async throws -> AppleCredential {
        let nonce = AppleNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        configure(request, nonce: nonce)
        let session = Session()
        let authorization = try await session.perform(request)
        return try credential(from: authorization, nonce: nonce)
    }

    /// Holds the controller and its delegate for as long as the sheet is up;
    /// `ASAuthorizationController` keeps only a weak reference to either.
    @MainActor
    private final class Session: NSObject, ASAuthorizationControllerDelegate,
        ASAuthorizationControllerPresentationContextProviding
    {
        private var continuation: CheckedContinuation<ASAuthorization, any Error>?
        private var controller: ASAuthorizationController?

        func perform(_ request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorization {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                self.controller = controller
                controller.performRequests()
            }
        }

        nonisolated func authorizationController(
            controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
        ) {
            MainActor.assumeIsolated { finish(.success(authorization)) }
        }

        nonisolated func authorizationController(
            controller: ASAuthorizationController, didCompleteWithError error: any Error
        ) {
            MainActor.assumeIsolated { finish(.failure(error)) }
        }

        nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            }
        }

        private func finish(_ result: Result<ASAuthorization, any Error>) {
            continuation?.resume(with: result)
            continuation = nil
            controller = nil
        }
    }
}

/// Apple's Sign in with Apple button, wired to a fresh nonce per tap.
///
/// White on this app's near-black ground, which is the variant Apple's
/// guidelines give for dark backgrounds — and the one control in the app that
/// deliberately isn't drawn in the theme's own palette, because its look is
/// Apple's to specify.
struct AppleSignInButton: View {
    var label: SignInWithAppleButton.Label = .signIn
    let onCredential: (AppleCredential) -> Void
    let onError: (any Error) -> Void

    @State private var nonce = AppleNonce()

    var body: some View {
        SignInWithAppleButton(label) { request in
            let fresh = AppleNonce()
            nonce = fresh
            AppleAuthorization.configure(request, nonce: fresh)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                do {
                    onCredential(try AppleAuthorization.credential(from: authorization, nonce: nonce))
                } catch {
                    onError(error)
                }
            case .failure(let error):
                if !AppleAuthorization.isCancellation(error) { onError(error) }
            }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

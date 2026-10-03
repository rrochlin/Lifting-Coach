import Foundation

/// Where phase 2 lives. Every value here is public by design.
///
/// Each one ships inside the app and is readable by anyone holding the binary;
/// access is the identity pool's job, not the obscurity of an id. They're the
/// resource ids recorded in `server/INFRA-SPEC.md` §12, and the Terraform in
/// `terraform-infrastructure/lift-coach/` is what owns them — if one changes
/// there, it changes here.
public struct CloudConfig: Sendable, Equatable {
    public var region: String
    /// The Cognito Hosted UI, which serves both email sign-in and Sign in with
    /// Apple. One flow for both, already verified end to end (§11 step 10).
    public var authDomain: URL
    public var clientID: String
    public var userPoolID: String
    public var identityPoolID: String
    public var bucket: String
    /// Registered as the app client's only callback URL. The scheme is never
    /// opened by the system — `ASWebAuthenticationSession` intercepts it —
    /// so it needs no `CFBundleURLSchemes` entry.
    public var redirectURI: String
    /// The Lambda that deletes an account — `AccountDeletion`. Named rather
    /// than addressed by URL: the phone calls Lambda's `Invoke` API directly.
    public var deleteAccountFunction: String

    public init(
        region: String, authDomain: URL, clientID: String, userPoolID: String,
        identityPoolID: String, bucket: String, redirectURI: String,
        deleteAccountFunction: String = "lift-coach-prod-delete-account"
    ) {
        self.region = region
        self.authDomain = authDomain
        self.clientID = clientID
        self.userPoolID = userPoolID
        self.identityPoolID = identityPoolID
        self.bucket = bucket
        self.redirectURI = redirectURI
        self.deleteAccountFunction = deleteAccountFunction
    }

    public static let production = CloudConfig(
        region: "us-west-2",
        authDomain: URL(string: "https://lift-coach-prod.auth.us-west-2.amazoncognito.com")!,
        clientID: "7b21re969qgped3sfqtit9e5c7",
        userPoolID: "us-west-2_IdjBHNPTi",
        identityPoolID: "us-west-2:4ceed955-559e-4395-9537-9672249ceeb6",
        bucket: "lift-coach-prod-snapshots",
        redirectURI: "liftcoach://callback",
        deleteAccountFunction: "lift-coach-prod-delete-account"
    )

    /// The `iss` of this pool's tokens, which is also the key the identity pool
    /// expects in its `Logins` map.
    public var issuer: String {
        "cognito-idp.\(region).amazonaws.com/\(userPoolID)"
    }

    public var callbackScheme: String {
        String(redirectURI.prefix { $0 != ":" })
    }
}

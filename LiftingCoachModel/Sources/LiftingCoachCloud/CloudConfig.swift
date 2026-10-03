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
    /// The user pool's public app client. Sign-in is native Sign in with
    /// Apple through `UserPoolAuth` — there is no Hosted UI (INFRA-SPEC §3.5).
    public var clientID: String
    public var userPoolID: String
    public var identityPoolID: String
    public var bucket: String
    /// The Lambda that deletes an account — `AccountDeletion`. Named rather
    /// than addressed by URL: the phone calls Lambda's `Invoke` API directly.
    public var deleteAccountFunction: String

    public init(
        region: String, clientID: String, userPoolID: String,
        identityPoolID: String, bucket: String,
        deleteAccountFunction: String = "lift-coach-prod-delete-account"
    ) {
        self.region = region
        self.clientID = clientID
        self.userPoolID = userPoolID
        self.identityPoolID = identityPoolID
        self.bucket = bucket
        self.deleteAccountFunction = deleteAccountFunction
    }

    public static let production = CloudConfig(
        region: "us-west-2",
        clientID: "7b21re969qgped3sfqtit9e5c7",
        userPoolID: "us-west-2_IdjBHNPTi",
        identityPoolID: "us-west-2:4ceed955-559e-4395-9537-9672249ceeb6",
        bucket: "lift-coach-prod-snapshots",
        deleteAccountFunction: "lift-coach-prod-delete-account"
    )

    /// The `iss` of this pool's tokens, which is also the key the identity pool
    /// expects in its `Logins` map.
    public var issuer: String {
        "cognito-idp.\(region).amazonaws.com/\(userPoolID)"
    }
}

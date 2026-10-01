import Foundation
import LiftingCoachCloud
import Security

/// The sign-in tokens, in the Keychain.
///
/// Keychain rather than `UserDefaults` because the refresh token is a thirty-day
/// credential for this lifter's whole cloud copy. Two attributes are choices:
///
/// - **`AfterFirstUnlockThisDeviceOnly`.** *After first unlock* because uploads
///   run when the app goes to background, often with the phone locked in a
///   pocket; `WhenUnlocked` would make every one of those fail. *This device
///   only* so an encrypted iPhone backup restored onto another phone doesn't
///   arrive already signed in as somebody — signing in again is cheap, and an
///   identity that travels without being asked is not.
/// - **One item, the whole token set as JSON.** The id token says *who*, the
///   refresh token says *still allowed*; storing them apart invites a state
///   where one exists without the other.
struct TokenStore: Sendable {
    let service: String

    init(service: String = "com.rrochlin.LiftingCoach.cognito") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "tokens",
        ]
    }

    func load() -> CognitoTokens? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(CognitoTokens.self, from: data)
    }

    func save(_ tokens: CognitoTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

import Foundation

/// Which code this binary is, read back out of `Info.plist`.
///
/// Exists because the question "which build was the feedback from, and what
/// was in it?" once had no answer. Build 68 left a section of gym-floor notes
/// in `notes/Feedback.md`, and weeks later it mattered whether that build
/// carried a particular migration — which could only be inferred from commit
/// timestamps against upload times, because nothing in the artifact said.
/// `Tools/testflight.sh` now stamps the commit into `LCGitCommit`, and Profile
/// shows it, so the person holding the phone can read it off the screen.
///
/// A local Xcode or simulator build reads `unknown`: only the release script
/// knows the commit, and claiming one it didn't stamp would be the exact
/// failure this is here to prevent.
struct BuildInfo {
    let version: String
    let build: String
    let commit: String

    static let current = BuildInfo(bundle: .main)

    init(bundle: Bundle) {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String) ?? "unknown"
        }
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
        commit = value("LCGitCommit")
    }

    /// `0.1.0 (103) · a1b2c3d` — what a lifter would quote in a bug report.
    var summary: String {
        "\(version) (\(build)) · \(commit)"
    }
}

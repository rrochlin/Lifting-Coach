import AuthenticationServices
import SwiftUI

/// Profile's account and backup section: sign in, see what the cloud holds, and
/// — when the cloud copy changed under this phone — choose what happens next.
///
/// **The conflict panel is the part worth reading.** Every upload is
/// conditional (`SnapshotSync`), so when S3 refuses one, backups stop and this
/// asks. On these phones the usual cause is a reinstall: a fresh database, a
/// forgotten etag, and a cloud copy holding the real history. A blind upload
/// there would have replaced years of training with an empty log; instead the
/// lifter sees both options, named by what they keep and what they replace
/// (Core Tenets §1).
struct AccountSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var isWorking = false
    @State private var message: String?
    @State private var confirmRestore = false
    @State private var confirmReplace = false

    private var cloud: CloudStatus { environment.cloud }

    var body: some View {
        SectionLabel(text: "account", accent: Theme.signal).panelRow()
            .task { await environment.refreshCloud() }

        if let outcome = cloud.launchRestore {
            launchRestoreBanner(outcome)
        }

        if cloud.hasConflict, cloud.session != nil {
            conflictPanel
        }

        Panel {
            VStack(alignment: .leading, spacing: 10) {
                if let session = cloud.session {
                    signedIn(session)
                } else {
                    signedOut
                }
                if let message {
                    Text(message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.alert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .panelRow()
        .themedConfirm(
            isPresented: $confirmRestore,
            title: "Restore the cloud backup?",
            message: "This phone's database is replaced with the backup the next time the app opens. Anything on this phone that isn't in the backup would be lost — so if this phone has workouts the backup doesn't, the restore is refused rather than done.",
            confirmLabel: "Restore",
            confirmRole: nil
        ) {
            run { try await environment.stageRestore() }
        }
        .themedConfirm(
            isPresented: $confirmReplace,
            title: "Replace the cloud backup?",
            message: "The cloud backup\(Self.describe(cloud.remote)) is replaced with this phone's data. Use this when this phone has the log you want to keep.",
            confirmLabel: "Replace"
        ) {
            run { await environment.replaceCloudCopy() }
        }
    }

    // MARK: States

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 10) {
            Readout(label: "status", value: "Local only", accent: Theme.inkMuted)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            actionButton(isWorking ? "SIGNING IN…" : "SIGN IN", icon: "person.crop.circle") {
                run { try await signIn() }
            }
            Text("Backs your training log up to the cloud after each workout. Email and Sign in with Apple are separate accounts — pick one and keep using it.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signedIn(_ session: AuthSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Readout(label: "signed in", value: session.email ?? String(session.subject.prefix(8)), accent: Theme.ink)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Readout(label: "backup", value: backupSummary, accent: cloud.remote == nil ? Theme.inkMuted : Theme.ink)
            if cloud.restoreStaged {
                Text("A restore is ready. Close the app fully and reopen it to apply it.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.live)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure = cloud.failure {
                Text("Last backup failed: \(failure)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                actionButton("BACK UP NOW", icon: "icloud.and.arrow.up") {
                    run { await environment.backUpNow() }
                }
                .disabled(cloud.hasConflict || cloud.restoreStaged)
                actionButton("SIGN OUT", icon: nil, tint: Theme.inkMuted) {
                    run { await environment.signOut() }
                }
            }
        }
    }

    /// Amber because it's the one thing on this screen waiting on the lifter.
    private var conflictPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("CLOUD BACKUP CHANGED")
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.live)
                Text("The cloud has a backup\(Self.describe(cloud.remote)) that this phone didn't write — from another phone, or from before the app was reinstalled. Backups are paused until you choose which to keep.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !cloud.restoreStaged {
                    actionButton("KEEP THE CLOUD BACKUP — RESTORE IT", icon: "icloud.and.arrow.down", tint: Theme.live) {
                        confirmRestore = true
                    }
                    actionButton("KEEP THIS PHONE'S DATA — REPLACE IT", icon: "icloud.and.arrow.up", tint: Theme.inkMuted) {
                        confirmReplace = true
                    }
                }
            }
        }
        .panelRow()
    }

    private func launchRestoreBanner(_ outcome: PendingRestore.Outcome) -> some View {
        Panel {
            Group {
                switch outcome {
                case .restored(let workouts):
                    Text("Restored from the cloud backup — \(workouts) workout\(workouts == 1 ? "" : "s").")
                        .foregroundStyle(Theme.signal)
                case .refused(let reason):
                    Text(reason).foregroundStyle(Theme.alert)
                }
            }
            .font(Theme.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .panelRow()
    }

    // MARK: Pieces

    private var backupSummary: String {
        guard let remote = cloud.remote else { return "None yet" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(remote.byteCount), countStyle: .file)
        guard let date = remote.uploadedAt else { return size }
        return "\(date.formatted(.relative(presentation: .named))) · \(size)"
    }

    private static func describe(_ remote: SnapshotDescriptor?) -> String {
        guard let date = remote?.uploadedAt else { return "" }
        return " from \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func signIn() async throws {
        let session = webAuthenticationSession
        try await environment.signIn { url, scheme in
            // Ephemeral: no cookie outlives the sign-in, so signing out on the
            // phone means signed out, not "one tap from back in as whoever
            // last used Safari's session".
            try await session.authenticate(
                using: url,
                callbackURLScheme: scheme,
                preferredBrowserSession: .ephemeral
            )
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await work()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // Backing out of the sign-in page isn't an error worth a word.
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func actionButton(
        _ title: String, icon: String?, tint: Color = Theme.signal, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 14, weight: .medium))
                }
                Text(title).font(Theme.label).tracking(1.2)
            }
            .foregroundStyle(isWorking ? Theme.inkMuted : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isWorking ? Theme.hairline : tint.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}

import SwiftUI
import LiftingCoachModel

/// Account management and service connections, per `Features/User Profile.md`.
///
/// Most of this page is inherently phase 2 — sign in/out and SSO need Cognito.
/// Data export/import is the one part that's local-only and buildable now, and
/// `Ideas.md` calls importing from other apps out as crucial.
///
/// It's also where the app's one real setting lives: the unit weights are read
/// in. This screen was still wearing default iOS chrome while every other tab
/// was themed; adding a control the lifter is meant to *find* was the point at
/// which that stopped being acceptable.
struct UserProfileView: View {
    @Environment(AppEnvironment.self) private var environment

    /// The archive being written, then the archive to hand off. `nil` between.
    @State private var isExporting = false
    @State private var exportedFile: SharedFile?
    @State private var exportSummary: String?
    @State private var exportError: String?
    @State private var isBrowsingExercises = false
    #if DEBUG
    @State private var didOpenLaunchLibrary = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                unitsSection
                referenceSection
                accountSection
                dataSection
            }
            .listStyle(.plain)
            .screenGround()
            .navigationTitle("Profile")
            .sheet(item: $exportedFile) { file in
                ShareSheet(url: file.url)
            }
            #if DEBUG
            .task {
                // Latched: `.task` re-runs on every return to this tab, and a
                // sheet that re-presents itself reads as a bug.
                guard !didOpenLaunchLibrary, LaunchArguments.opensExerciseLibrary else { return }
                didOpenLaunchLibrary = true
                try? await Task.sleep(for: .milliseconds(400))
                isBrowsingExercises = true
            }
            #endif
            .sheet(isPresented: $isBrowsingExercises) {
                // No `onPick`: browsing. See `ExercisePicker`.
                #if DEBUG
                ExercisePicker(initialDetailQuery: LaunchArguments.exerciseLibraryQuery)
                #else
                ExercisePicker()
                #endif
            }
        }
    }

    @ViewBuilder
    private var unitsSection: some View {
        SectionLabel(text: "units", accent: Theme.signal).panelRow()

        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(WeightUnit.allCases, id: \.self) { unit in
                        unitButton(unit)
                    }
                }
                // Says what switching does and, more importantly, what it
                // doesn't. A lifter who thinks the button rewrites their log
                // won't press it.
                Text("Changes how weights are shown and entered. Nothing already logged is rewritten — a set logged in lb stays a lb entry on disk.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .panelRow()
    }

    private func unitButton(_ unit: WeightUnit) -> some View {
        let selected = environment.weightUnit == unit
        return Button {
            environment.setWeightUnit(unit)
        } label: {
            VStack(spacing: 2) {
                Text(unit.symbol.uppercased())
                    .font(Theme.data(17, weight: selected ? .semibold : .regular))
                Text(unit == .pounds ? "pounds" : "kilograms")
                    .font(Theme.label)
                    .tracking(1.1)
            }
            .foregroundStyle(selected ? Theme.void : Theme.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? Theme.signal : Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? Theme.signal : Theme.fieldEdge, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var accountSection: some View {
        SectionLabel(text: "account").panelRow()

        Panel {
            VStack(alignment: .leading, spacing: 9) {
                Readout(
                    label: "status",
                    value: environment.backend.isAvailable ? "Signed in" : "Local only",
                    accent: environment.backend.isAvailable ? Theme.ink : Theme.inkMuted
                )
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("Sign in, SSO, and account deletion need the phase 2 backend.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .panelRow()
    }

    /// The catalog, readable.
    ///
    /// ~870 vendored entries with equipment, mechanic, force, level, both
    /// muscle lists and step-by-step instructions have been on the phone since
    /// the catalog import landed, and the only way to read any of it was to go
    /// and *choose* an exercise — which is a verb you only reach for while
    /// editing a workout. Same screen, same search, same usage ordering; the
    /// only difference is that nothing here commits.
    ///
    /// Lives on Profile because it's reference material rather than part of the
    /// training loop. The in-the-moment route is the tracker's own `…` menu
    /// ("Exercise Info"), which opens straight to the lift in front of you.
    @ViewBuilder
    private var referenceSection: some View {
        SectionLabel(text: "reference").panelRow()

        Button { isBrowsingExercises = true } label: {
            Panel {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("EXERCISE LIBRARY")
                            .font(Theme.label)
                            .tracking(1.4)
                            .foregroundStyle(Theme.signal)
                        Text("Search the catalog: what each lift works, how it's performed, and everything you've logged under it.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .panelRow()
    }

    @ViewBuilder
    private var dataSection: some View {
        SectionLabel(text: "data", accent: Theme.signal).panelRow()

        Panel(accent: exportError == nil ? Theme.hairline : Theme.alert.opacity(0.5)) {
            VStack(alignment: .leading, spacing: 10) {
                exportButton

                if let exportSummary {
                    Text(exportSummary)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let exportError {
                    Text(exportError)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.alert)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Says what the file is, because the point of an export is
                // being able to trust it years later. There is no server behind
                // this app until phase 2 — the log lives on one phone.
                Text("Every logged workout, your maxes, bodyweight history and the whole plan, as one JSON file. It's the complete archive, not a summary — nothing is dropped for being redundant.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelRow()

        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("IMPORT — NOT HERE")
                    .font(Theme.label)
                    .tracking(1.4)
                    .foregroundStyle(Theme.inkFaint)
                // Stated rather than left as an empty half of the section: this
                // is a decision, not an unfinished feature. See CLAUDE.md's
                // `scripts/` section and Roadmap.md.
                Text("Bringing history in from another app is a translation, and it happens once, by hand, in the repo's import pipeline. The only import surface this app will have is file upload in the phase 2 coach chat.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelRow()
    }

    private var exportButton: some View {
        Button {
            Task { await exportData() }
        } label: {
            HStack(spacing: 8) {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.signal)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium))
                }
                Text(isExporting ? "EXPORTING…" : "EXPORT DATA")
                    .font(Theme.label)
                    .tracking(1.2)
            }
            .foregroundStyle(isExporting ? Theme.inkMuted : Theme.signal)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isExporting ? Theme.hairline : Theme.signal.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExporting)
    }

    /// Builds the archive off the main actor and hands the file to the share
    /// sheet.
    ///
    /// Off-main is not optional here: a full export hydrates every set of every
    /// workout, which against five years of history is thousands of queries. On
    /// the main actor that's a frozen screen with no way to tell whether it's
    /// working.
    private func exportData() async {
        guard let user = environment.currentUser else { return }
        isExporting = true
        exportError = nil
        exportSummary = nil

        let exporter = environment.exporter
        let result = await Task.detached(priority: .userInitiated) { () -> Result<SharedFile, any Error> in
            do {
                let archive = try exporter.export(for: user.id)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(archive)

                // A real file rather than in-memory data, because the share
                // sheet's destinations are mostly files — Files, Mail, AirDrop
                // — and a named file is what makes the archive recognisable a
                // year later. Temp directory: the system reclaims it, and the
                // copy that matters is wherever the lifter puts it.
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(archive.suggestedFilename())
                try data.write(to: url, options: .atomic)
                return .success(SharedFile(url: url))
            } catch {
                return .failure(error)
            }
        }.value

        isExporting = false
        switch result {
        case .success(let file):
            exportSummary = summary(of: file.url)
            exportedFile = file
        case .failure(let error):
            exportError = error.localizedDescription
        }
    }

    /// What was actually written, in the lifter's terms. An export that says
    /// nothing about its contents is one you have to open to trust.
    private func summary(of url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "Wrote \(url.lastPathComponent) — \(bytes)."
    }
}

#Preview {
    UserProfileView()
        .environment(AppEnvironment.preview())
}

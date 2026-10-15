import LiftingCoachModel
import LiftingCoachPersistence
import SwiftUI

/// Every conversation, newest first — INFRA-SPEC §13.6. Tap to open, swipe to
/// delete.
struct CoachConversationList: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private var coach: CoachModel { environment.coach }

    var body: some View {
        NavigationStack {
            List {
                if coach.conversations.isEmpty {
                    Text("No conversations yet.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkMuted)
                        .panelRow()
                }
                ForEach(coach.conversations) { conversation in
                    Button {
                        coach.open(conversation.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title)
                                    .font(Theme.heading)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2)
                                Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.inkMuted)
                            }
                            Spacer(minLength: 6)
                            if conversation.id == coach.currentConversationID {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.signal)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .panelRow()
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            coach.deleteConversation(conversation.id)
                        }
                        .tint(Theme.alert)
                    }
                }
            }
            .listStyle(.plain)
            .screenGround()
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New") {
                        coach.startNewConversation()
                        dismiss()
                    }
                    .foregroundStyle(Theme.signal)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.signal)
                }
            }
        }
    }
}

/// What the coach knows about the lifter — INFRA-SPEC §13.7, modelled on
/// Claude's memory: the coach writes it as it learns, and the lifter can read,
/// correct, add to and delete every word of it. An edit here is marked as the
/// lifter's own, which the coach is told.
struct CoachProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CoachMemoryEntry?
    @State private var adding: CoachMemoryEntry.Category?
    @State private var confirmClear = false

    private var coach: CoachModel { environment.coach }

    var body: some View {
        NavigationStack {
            List {
                Text("The coach keeps these notes as it learns about you, and reads them with every message. Change anything that's wrong; delete anything you'd rather it didn't know. It never changes your plan or your log.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .panelRow()

                ForEach(CoachMemoryEntry.Category.allCases, id: \.self) { category in
                    section(category)
                }

                if !coach.memory.isEmpty {
                    Button("CLEAR EVERYTHING", role: .destructive) { confirmClear = true }
                        .font(Theme.label)
                        .tracking(1.2)
                        .foregroundStyle(Theme.alert)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .panelRow()
                }
            }
            .listStyle(.plain)
            .screenGround()
            .navigationTitle("What your coach knows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.signal)
                }
            }
            .sheet(item: $editing) { entry in
                MemoryEditor(title: entry.category.title, text: entry.text) { coach.editMemory(entry.id, text: $0) }
            }
            .sheet(item: $adding) { category in
                MemoryEditor(title: category.title, text: "") { coach.addMemory($0, category: category) }
            }
            .themedConfirm(
                isPresented: $confirmClear,
                title: "Clear what the coach knows?",
                message: "Every note is deleted. Your conversations stay; the coach starts learning about you again.",
                confirmLabel: "Clear"
            ) { coach.clearMemory() }
        }
    }

    @ViewBuilder
    private func section(_ category: CoachMemoryEntry.Category) -> some View {
        let entries = coach.memory.filter { $0.category == category }
        HStack {
            SectionLabel(text: category.title.lowercased(), accent: Theme.signal)
            Button { adding = category } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.signal)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to \(category.title)")
        }
        .panelRow()
        if entries.isEmpty {
            Text("Nothing yet.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkFaint)
                .panelRow()
        }
        ForEach(entries) { entry in
            Button { editing = entry } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(entry.source == .lifter ? "YOU · \(entry.updatedAt.formatted(date: .abbreviated, time: .omitted))"
                                                 : "COACH · \(entry.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.label)
                        .tracking(1.1)
                        .foregroundStyle(Theme.inkFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .panelRow()
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { coach.deleteMemory(entry.id) }
                    .tint(Theme.alert)
            }
        }
    }
}

extension CoachMemoryEntry.Category: Identifiable {
    public var id: String { rawValue }
}

/// One note, written or rewritten by the lifter.
private struct MemoryEditor: View {
    let title: String
    @State var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .padding(12)
                    .background(Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("\(trimmed.count) / \(CoachMemoryEntry.textLimit)")
                    .font(Theme.label)
                    .foregroundStyle(trimmed.count > CoachMemoryEntry.textLimit ? Theme.alert : Theme.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
            }
            .padding(16)
            .background(Theme.void)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmed)
                        dismiss()
                    }
                    .foregroundStyle(Theme.signal)
                    .disabled(trimmed.isEmpty || trimmed.count > CoachMemoryEntry.textLimit)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

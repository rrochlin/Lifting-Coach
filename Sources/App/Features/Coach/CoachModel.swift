import Foundation
import LiftingCoachModel
import LiftingCoachPersistence
import Observation
import UIKit

/// The coach conversation as the app shows it, and the one owner of sending.
///
/// **Owned by `AppEnvironment`, not by the Coach screen** — that's what makes
/// "navigate away before the reply comes" safe. The screen only reads this and
/// asks it to send; the delivery runs here, so switching tabs doesn't cancel
/// it, and it holds a background task so leaving the app doesn't either. The
/// guarantees underneath — written before sent, sent in order, answered once —
/// are `CoachOutbox`'s, tested in the model package. INFRA-SPEC §13.
@MainActor
@Observable
final class CoachModel {
    /// Every conversation, newest first.
    private(set) var conversations: [CoachConversation] = []
    /// The conversation on screen, or `nil` for a new one not yet started —
    /// it's created by its first message (`CoachStore.addPending`).
    private(set) var currentConversationID: String?
    /// The conversation on screen's messages.
    private(set) var messages: [CoachMessage] = []
    /// What the coach knows about the lifter (INFRA-SPEC §13.7).
    private(set) var memory: [CoachMemoryEntry] = []
    /// Whether any conversation has a message waiting — what deciding to
    /// deliver depends on, wherever the lifter is looking.
    private var anyPending = false
    /// A delivery is running. With a pending message, this is the typing
    /// indicator.
    private(set) var isDelivering = false
    /// Why messages are still waiting, if they are.
    private(set) var stopped: CoachOutbox.Stop?
    /// Replies that arrived while the Coach tab wasn't on screen: the badge.
    private(set) var unread = 0
    /// Set by the Coach screen while it's visible.
    var isVisible = false {
        didSet { if isVisible { unread = 0 } }
    }

    /// Apple's guideline 5.1.2(i): explicit permission before personal data
    /// goes to an AI model. Per install, which is what a permission is.
    private(set) var hasConsented: Bool

    private let store: CoachStore
    private let outbox: CoachOutbox
    private let onReplied: () -> Void
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(15)

    private static let consentKey = "coach.consent.v1"

    init(store: CoachStore, outbox: CoachOutbox, onReplied: @escaping () -> Void) {
        self.store = store
        self.outbox = outbox
        self.onReplied = onReplied
        hasConsented = UserDefaults.standard.bool(forKey: Self.consentKey)
        // Opens on the most recent conversation.
        currentConversationID = (try? store.conversations())?.first?.id
        reload()
    }

    /// The conversation on screen has a message waiting: the typing indicator.
    var hasPending: Bool {
        messages.contains { $0.role == .lifter && $0.status == .pending }
    }

    var currentTitle: String {
        conversations.first { $0.id == currentConversationID }?.title ?? "New conversation"
    }

    // MARK: Conversations

    func startNewConversation() {
        currentConversationID = nil
        reload()
    }

    func open(_ conversationID: String) {
        currentConversationID = conversationID
        reload()
    }

    func deleteConversation(_ id: String) {
        try? store.deleteConversation(id)
        if currentConversationID == id { currentConversationID = nil }
        reload()
    }

    // MARK: The lifter profile

    func editMemory(_ id: String, text: String) {
        try? store.editMemory(id, text: text)
        memoryChanged()
    }

    func addMemory(_ text: String, category: CoachMemoryEntry.Category) {
        try? store.addMemory(text, category: category)
        memoryChanged()
    }

    func deleteMemory(_ id: String) {
        try? store.deleteMemory(id)
        memoryChanged()
    }

    func clearMemory() {
        try? store.clearMemory()
        memoryChanged()
    }

    /// The profile is in the database, so the lifter's edits back up too.
    private func memoryChanged() {
        reload()
        onReplied()
    }

    func consent() {
        UserDefaults.standard.set(true, forKey: Self.consentKey)
        hasConsented = true
    }

    /// Writes the message, then sends it. The write comes first and is the
    /// only part that has to succeed for the message to be safe.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= CoachMessage.characterLimit else { return }
        do {
            let message = try store.addPending(trimmed, in: currentConversationID)
            currentConversationID = message.conversationID
        } catch {
            return
        }
        reload()
        deliver()
    }

    /// RETRY on a failed message.
    func retry(_ id: String) {
        try? store.markPending(id)
        reload()
        deliver()
    }

    /// Sends whatever is pending. Called on send, when the Coach tab appears,
    /// when the app becomes active, and after sign-in — any of which may find
    /// messages a killed app left behind.
    func deliver() {
        guard hasConsented, anyPending, !isDelivering else { return }
        retryTask?.cancel()
        isDelivering = true
        let outbox = outbox
        let app = UIApplication.shared
        // Long enough for one reply; iOS ends it for us if it runs over, and
        // the message is still pending for next time.
        let task = app.beginBackgroundTask(withName: "coach-message")
        Task { @MainActor in
            let answered = await outbox.deliverPending()
            stopped = await outbox.stopped
            isDelivering = false
            reload()
            if answered > 0 {
                if !isVisible { unread += answered }
                retryDelay = .seconds(15)
                onReplied()
            }
            if stopped == .unavailable { scheduleRetry() }
            app.endBackgroundTask(task)
        }
    }

    /// Unreachable now isn't unreachable for good. Backs off to two minutes;
    /// the app becoming active tries again sooner.
    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(120))
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    private func reload() {
        conversations = (try? store.conversations()) ?? conversations
        if let currentConversationID {
            messages = (try? store.messages(in: currentConversationID)) ?? messages
        } else {
            messages = []
        }
        memory = (try? store.memory()) ?? memory
        anyPending = ((try? store.all()) ?? []).contains { $0.role == .lifter && $0.status == .pending }
    }
}

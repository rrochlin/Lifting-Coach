import Foundation
import LiftingCoachModel

/// Sends the lifter's pending coach messages, oldest first, until none are
/// left or something stops it (INFRA-SPEC §13.1).
///
/// The shape of `SnapshotSync`, for the same reasons: an actor, so two
/// triggers can't send the same message at once; the network behind a closure,
/// so the policy is tested without one; and state that lives on disk, so a
/// process killed in the middle loses nothing. **A message is only marked sent
/// in the same transaction that stores its reply** (`CoachStore.deliver`) —
/// until then it is pending, and pending means "send this again".
///
/// Sending again is safe because the server answers a message id at most
/// once: a re-sent message whose reply was lost gets that same reply back.
public actor CoachOutbox {
    /// What the server said instead of a reply.
    public enum Refusal: Error, Equatable, Sendable {
        /// The session is gone. Messages wait until the lifter signs in.
        case signInRequired
        /// The server won't answer this message as sent. Marked failed with
        /// the reason; sending it unchanged would be refused again.
        case rejected(String)
        /// The model or the network failed. The message stays pending.
        case unavailable
    }

    public struct Reply: Equatable, Sendable {
        public var id: String
        public var text: String
        public var createdAt: Date
        /// What the coach changed in the lifter profile (INFRA-SPEC §13.7).
        public var memoryChanges: [CoachMemoryChange]

        public init(id: String, text: String, createdAt: Date, memoryChanges: [CoachMemoryChange] = []) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
            self.memoryChanges = memoryChanges
        }
    }

    public struct Turn: Equatable, Sendable {
        public var role: CoachMessage.Role
        public var text: String
    }

    /// Why delivery stopped with messages still pending, if it did.
    public enum Stop: Equatable, Sendable {
        case signInRequired
        case unavailable
    }

    /// What goes with each message besides its history: the whole lifter
    /// profile, and the lifter's local date — without it "a meet next June"
    /// was recorded as the June already past.
    public struct Context: Equatable, Sendable {
        public var memory: [CoachMemoryEntry]
        public var today: String
        /// So dates read from the log are shown in the lifter's own days.
        public var timeZone: String = TimeZone.current.identifier
    }

    public typealias Send = @Sendable (_ id: String, _ text: String, _ history: [Turn], _ context: Context) async throws -> Reply

    /// How many earlier messages go with each one. The server bounds it too.
    public static let historyLimit = 40

    private let store: CoachStore
    private let send: Send
    private var isDelivering = false
    private var wantsAnotherPass = false

    /// The last reason delivery stopped, or `nil` once everything was sent.
    public private(set) var stopped: Stop?

    private let now: @Sendable () -> Date

    public init(store: CoachStore, now: @escaping @Sendable () -> Date = { Date() }, send: @escaping Send) {
        self.store = store
        self.now = now
        self.send = send
    }

    /// The lifter's local calendar date, `yyyy-MM-dd`.
    static func localDate(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Delivers every pending message, in order. Returns how many were
    /// answered. Safe to call from anywhere, as often as wanted: a call while
    /// a delivery is running asks it to make one more pass and returns.
    @discardableResult
    public func deliverPending() async -> Int {
        guard !isDelivering else {
            wantsAnotherPass = true
            return 0
        }
        isDelivering = true
        defer { isDelivering = false }

        var answered = 0
        repeat {
            wantsAnotherPass = false
            answered += await deliverPass()
        } while wantsAnotherPass && stopped == nil
        return answered
    }

    private func deliverPass() async -> Int {
        var answered = 0
        while true {
            guard let conversation = try? store.all(),
                  let message = conversation.first(where: { $0.role == .lifter && $0.status == .pending })
            else {
                stopped = nil
                return answered
            }
            do {
                // The profile is read fresh for each message, so a reply that
                // just changed it informs the next one.
                let context = Context(memory: (try? store.memory()) ?? [], today: Self.localDate(now()))
                let reply = try await send(
                    message.id, message.text, Self.history(for: message, in: conversation), context
                )
                try store.deliver(
                    reply: CoachMessage(
                        id: reply.id, role: .coach, text: reply.text, createdAt: reply.createdAt,
                        inReplyTo: message.id, memoryChanges: reply.memoryChanges
                    ),
                    answering: message.id
                )
                answered += 1
            } catch Refusal.rejected(let reason) {
                try? store.markFailed(message.id, reason: reason)
                // Not a stop: the next pending message is its own question.
            } catch Refusal.signInRequired {
                stopped = .signInRequired
                return answered
            } catch {
                // `.unavailable`, a network error, a timeout: try later.
                stopped = .unavailable
                return answered
            }
        }
    }

    /// What was said before a message, as the server wants it: every
    /// answered exchange so far, in time order.
    ///
    /// Not "everything above it on screen". A lifter who sends a second
    /// message before the first reply lands sees, correctly, *One, Two,
    /// re: One* — and the second message's context still has to include that
    /// reply, since it exists by the time the second is sent. Messages go out
    /// strictly in order, so anything answered is earlier in the
    /// conversation; anything still pending is later and isn't included. A
    /// failed message never got an answer, so leaving it in would put two of
    /// the lifter's turns in a row for no reason.
    static func history(for message: CoachMessage, in conversation: [CoachMessage]) -> [Turn] {
        conversation
            // This conversation's exchanges only: a new conversation is a
            // fresh topic, which is what it's for (INFRA-SPEC §13.6).
            .filter { $0.conversationID == message.conversationID }
            .filter { $0.id != message.id && ($0.role == .coach || $0.status == .sent) }
            .suffix(historyLimit)
            .map { Turn(role: $0.role, text: $0.text) }
    }
}

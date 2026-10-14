import Foundation
import Testing
import LiftingCoachModel
@testable import LiftingCoachPersistence

/// The coach's delivery guarantees: nothing dropped, nothing answered twice,
/// in order. See `CoachOutbox`.
@Suite("Coach outbox")
struct CoachOutboxTests {
    /// A fake server: answers by message id, remembering what it answered —
    /// which is what the real one does (`coach.answer`).
    final class Server: @unchecked Sendable {
        var answered: [String: CoachOutbox.Reply] = [:]
        var calls: [(id: String, history: [CoachOutbox.Turn])] = []
        var failures: [Error] = []

        func send(_ id: String, _ text: String, _ history: [CoachOutbox.Turn]) throws -> CoachOutbox.Reply {
            calls.append((id, history))
            if !failures.isEmpty { throw failures.removeFirst() }
            if let reply = answered[id] { return reply }
            let reply = CoachOutbox.Reply(id: "\(id)-reply", text: "re: \(text)", createdAt: Date())
            answered[id] = reply
            return reply
        }
    }

    private func make() throws -> (CoachStore, CoachOutbox, Server) {
        let store = CoachStore(try AppDatabase.inMemory())
        let server = Server()
        let outbox = CoachOutbox(store: store) { id, text, history in
            try server.send(id, text, history)
        }
        return (store, outbox, server)
    }

    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("A message is on disk, pending, before anything is sent")
    func writtenFirst() throws {
        let (store, _, server) = try make()
        try store.addPending("How should I warm up?", at: t0)

        #expect(try store.all().map(\.status) == [.pending])
        #expect(server.calls.isEmpty)
    }

    @Test("Delivery stores the reply and marks the message sent")
    func delivers() async throws {
        let (store, outbox, _) = try make()
        let message = try store.addPending("How should I warm up?", at: t0)

        #expect(await outbox.deliverPending() == 1)
        let all = try store.all()
        #expect(all.map(\.role) == [.lifter, .coach])
        #expect(all[0].status == .sent)
        #expect(all[1].text == "re: How should I warm up?")
        #expect(all[1].inReplyTo == message.id)
        #expect(await outbox.stopped == nil)
    }

    /// The case the whole design exists for: the app went away before the
    /// reply came back. The server answered; the phone never heard.
    @Test("A reply lost on the way back is recovered on the next delivery, not asked for twice")
    func recoversLostReply() async throws {
        let (store, outbox, server) = try make()
        let message = try store.addPending("Deload this week?", at: t0)
        // The server answered, then the response was lost.
        _ = try server.send(message.id, message.text, [])
        server.calls.removeAll()

        await outbox.deliverPending()

        // Re-sent with the same id, and the stored answer came back.
        #expect(server.calls.map(\.id) == [message.id])
        #expect(try store.all().map(\.text) == ["Deload this week?", "re: Deload this week?"])
    }

    @Test("Delivering the same reply twice stores it once")
    func idempotentStore() throws {
        let (store, _, _) = try make()
        let message = try store.addPending("Hi", at: t0)
        let reply = CoachMessage(id: "\(message.id)-reply", role: .coach, text: "Hello", createdAt: t0)
        try store.deliver(reply: reply, answering: message.id)
        try store.deliver(reply: reply, answering: message.id)
        #expect(try store.all().count == 2)
    }

    @Test("When the model is unavailable, messages stay pending and delivery stops")
    func unavailableKeepsPending() async throws {
        let (store, outbox, server) = try make()
        try store.addPending("One", at: t0)
        try store.addPending("Two", at: t0.addingTimeInterval(1))
        server.failures = [CoachOutbox.Refusal.unavailable]

        #expect(await outbox.deliverPending() == 0)
        #expect(await outbox.stopped == .unavailable)
        #expect(try store.all().map(\.status) == [.pending, .pending])
        // Stopped at the first: "Two" isn't sent ahead of "One".
        #expect(server.calls.count == 1)

        #expect(await outbox.deliverPending() == 2)
        #expect(await outbox.stopped == nil)
    }

    @Test("A network error is treated like unavailable, not like a refusal")
    func networkError() async throws {
        let (store, outbox, server) = try make()
        try store.addPending("One", at: t0)
        server.failures = [URLError(.notConnectedToInternet)]

        await outbox.deliverPending()
        #expect(try store.all().map(\.status) == [.pending])
    }

    @Test("A signed-out session holds everything until sign-in")
    func signedOut() async throws {
        let (store, outbox, server) = try make()
        try store.addPending("One", at: t0)
        server.failures = [CoachOutbox.Refusal.signInRequired]

        await outbox.deliverPending()
        #expect(await outbox.stopped == .signInRequired)
        #expect(try store.all().map(\.status) == [.pending])
    }

    @Test("A rejected message is marked failed with the reason, and the next one still goes")
    func rejected() async throws {
        let (store, outbox, server) = try make()
        let bad = try store.addPending("One", at: t0)
        try store.addPending("Two", at: t0.addingTimeInterval(1))
        server.failures = [CoachOutbox.Refusal.rejected("Message longer than 4000 characters")]

        await outbox.deliverPending()
        let all = try store.all()
        #expect(all.first { $0.id == bad.id }?.status == .failed("Message longer than 4000 characters"))
        #expect(all.map(\.role) == [.lifter, .lifter, .coach])

        // RETRY puts it back.
        try store.markPending(bad.id)
        await outbox.deliverPending()
        #expect(try store.all().filter { $0.role == .lifter }.map(\.status) == [.sent, .sent])
    }

    @Test("Messages go in order, each with the exchanges before it")
    func orderAndHistory() async throws {
        let (store, outbox, server) = try make()
        try store.addPending("One", at: t0)
        try store.addPending("Two", at: t0.addingTimeInterval(1))

        await outbox.deliverPending()
        #expect(server.calls.count == 2)
        #expect(server.calls[0].history.isEmpty)
        #expect(server.calls[1].history.map(\.text) == ["One", "re: One"])
    }

    @Test("A failed message isn't sent as history")
    func failedNotInHistory() throws {
        let t = { (s: Double) in Date(timeIntervalSince1970: 1_770_000_000 + s) }
        let conversation = [
            CoachMessage(id: "a", role: .lifter, text: "kept", createdAt: t(0)),
            CoachMessage(id: "a-reply", role: .coach, text: "answer", createdAt: t(1)),
            CoachMessage(id: "b", role: .lifter, text: "dropped", createdAt: t(2), status: .failed("x")),
            CoachMessage(id: "c", role: .lifter, text: "now", createdAt: t(3), status: .pending),
        ]
        #expect(CoachOutbox.history(for: conversation[3], in: conversation).map(\.text) == ["kept", "answer"])
    }

    @Test("History is bounded")
    func boundedHistory() {
        let conversation = (0..<100).map {
            CoachMessage(id: "\($0)", role: $0 % 2 == 0 ? .lifter : .coach, text: "\($0)",
                         createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let now = CoachMessage(id: "now", role: .lifter, text: "now", createdAt: Date(), status: .pending)
        #expect(CoachOutbox.history(for: now, in: conversation + [now]).count == CoachOutbox.historyLimit)
    }

    /// Two triggers at once — the tab appearing while the app comes to the
    /// foreground — must not send one message twice.
    @Test("Concurrent deliveries send each message once")
    func concurrent() async throws {
        let (store, outbox, server) = try make()
        try store.addPending("One", at: t0)
        async let a = outbox.deliverPending()
        async let b = outbox.deliverPending()
        _ = await (a, b)
        #expect(server.calls.count == 1)
        #expect(try store.all().count == 2)
    }
}

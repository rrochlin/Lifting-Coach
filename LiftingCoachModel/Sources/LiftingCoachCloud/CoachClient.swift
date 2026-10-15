import Foundation

/// Sends one coach message and returns its reply — INFRA-SPEC §13.
///
/// Lambda's `Invoke` API, SigV4-signed with the identity-pool credentials, the
/// same call `AccountDeletion` makes; the access token in the payload is what
/// says whose message it is. **Not responsible for not losing messages** —
/// that's `CoachOutbox`, on the phone, which calls this. All this has to get
/// right is telling the outbox which of three things happened: a reply, a
/// refusal it shouldn't resend, or a failure it should.
public struct CoachClient: Sendable {
    public struct Turn: Sendable, Equatable {
        public var role: String
        public var text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// A lifter-profile entry as the coach function takes it.
    public struct MemoryEntry: Sendable, Equatable {
        public var id: String
        public var category: String
        public var text: String
        public var source: String

        public init(id: String, category: String, text: String, source: String) {
            self.id = id
            self.category = category
            self.text = text
            self.source = source
        }
    }

    /// A change the coach made to the profile.
    public struct MemoryChange: Sendable, Equatable {
        public var op: String
        public var id: String
        public var category: String
        public var text: String
    }

    public struct Reply: Sendable, Equatable {
        public var id: String
        public var text: String
        public var createdAt: Date
        public var memory: [MemoryChange]
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case signInRequired
        case rejected(String)
        case unavailable

        public var errorDescription: String? {
            switch self {
            case .signInRequired: "Sign in again to send messages to the coach."
            case .rejected(let detail): "The coach couldn't take that message. \(detail)"
            case .unavailable: "The coach isn't reachable right now. Your message will send when it is."
            }
        }
    }

    public let config: CloudConfig
    let transport: HTTPTransport

    public init(config: CloudConfig = .production, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public var url: URL {
        URL(string: "https://lambda.\(config.region).amazonaws.com/2015-03-31/functions/")!
            .appendingPathComponent(config.coachFunction)
            .appendingPathComponent("invocations")
    }

    public func send(
        messageID: String, text: String, history: [Turn],
        memory: [MemoryEntry] = [], today: String = "",
        accessToken: String, credentials: AWSCredentials
    ) async throws -> Reply {
        let body = try JSONSerialization.data(withJSONObject: [
            "accessToken": accessToken,
            "messageId": messageID,
            "text": text,
            "history": history.map { ["role": $0.role, "text": $0.text] },
            "memory": memory.map { ["id": $0.id, "category": $0.category, "text": $0.text, "source": $0.source] },
            "today": today,
        ] as [String: Any])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The function's own timeout is 120 s; a reply that takes longer than
        // this is retried, and the server hands back the stored answer.
        request.timeoutInterval = 130
        SigV4.sign(&request, credentials: credentials, region: config.region, service: "lambda",
                   payloadSHA256: SigV4.payloadHash(body))

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            // Offline, timed out, cut off: the message stays pending.
            throw Failure.unavailable
        }
        // Throttled, or a Lambda-side 5xx: also "later".
        guard response.statusCode == 200 else {
            if response.statusCode == 403 { throw Failure.signInRequired }
            throw Failure.unavailable
        }
        // A handler that raised still answers 200; the header is the tell.
        if response.value(forHTTPHeaderField: "X-Amz-Function-Error") != nil {
            throw Failure.unavailable
        }

        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch reply["error"] as? String {
        case nil: break
        case "signInRequired": throw Failure.signInRequired
        case "badRequest": throw Failure.rejected((reply["detail"] as? String) ?? "")
        default: throw Failure.unavailable
        }
        guard
            let body = reply["reply"] as? [String: Any],
            let id = body["id"] as? String,
            let text = body["text"] as? String
        else { throw Failure.unavailable }
        let created = (body["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let changes = ((body["memory"] as? [[String: Any]]) ?? []).compactMap { change -> MemoryChange? in
            guard let op = change["op"] as? String, let id = change["id"] as? String else { return nil }
            return MemoryChange(
                op: op, id: id,
                category: (change["category"] as? String) ?? "", text: (change["text"] as? String) ?? ""
            )
        }
        return Reply(id: id, text: text, createdAt: created, memory: changes)
    }
}

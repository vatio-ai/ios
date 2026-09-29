import Foundation

/// The realtime half: one Action Cable subscription to the visitor's own
/// conversation. Not public -- the wire format is free to change, VatioChat is
/// the contract.
@MainActor
final class Cable {
    enum Event {
        case subscribed
        case rejected
        case typing(Bool)
        case message(VatioMessage)
        case feedback(VatioFeedback?)
        case closed
    }

    private let url: URL
    private let origin: String
    private let chatToken: String
    private let session: URLSession
    private let onEvent: @MainActor (Event) -> Void

    private weak var owner: AnyObject?
    private var task: URLSessionWebSocketTask?
    // Sorted keys, so the identifier the server echoes back is always the
    // same string this sent.
    private var identifier: String {
        let object = ["channel": "VisitorChatChannel", "chat_token": chatToken]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    init(
        url: URL, origin: String, chatToken: String, session: URLSession, owner: AnyObject,
        onEvent: @escaping @MainActor (Event) -> Void
    ) {
        self.owner = owner
        self.url = url
        self.origin = origin
        self.chatToken = chatToken
        self.session = session
        self.onEvent = onEvent
    }

    func connect() {
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("actioncable-v1-json, actioncable-unsupported", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        Task { await self.receive(on: task) }
    }

    func close() {
        guard let task else { return }
        self.task = nil
        send(["command": "unsubscribe", "identifier": identifier], on: task)
        task.cancel(with: .goingAway, reason: nil)
    }

    private func receive(on task: URLSessionWebSocketTask) async {
        while self.task === task {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await task.receive()
            } catch {
                break
            }
            guard self.task === task else { return }
            // The chat was released without close(). The server pings every
            // few seconds, so this is noticed soon after.
            guard owner != nil else {
                self.task = nil
                task.cancel(with: .goingAway, reason: nil)
                return
            }
            handle(frame, on: task)
        }
        // Closed by the network rather than by close(): report it once.
        if self.task === task {
            self.task = nil
            onEvent(.closed)
        }
    }

    private func handle(_ frame: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        let data: Data?
        switch frame {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let bytes): data = bytes
        @unknown default: data = nil
        }
        guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        switch json["type"] as? String {
        case "welcome":
            send(["command": "subscribe", "identifier": identifier], on: task)
        case "confirm_subscription":
            onEvent(.subscribed)
        case "reject_subscription":
            self.task = nil
            task.cancel(with: .normalClosure, reason: nil)
            onEvent(.rejected)
        case "ping", "disconnect":
            // A disconnect is followed by the socket closing, which is where
            // reconnecting happens.
            return
        default:
            guard let event = json["message"] as? [String: Any] else { return }
            switch event["type"] as? String {
            case "typing_start": onEvent(.typing(true))
            case "typing_stop": onEvent(.typing(false))
            case "message":
                guard let payload = event["message"],
                      let bytes = try? JSONSerialization.data(withJSONObject: payload),
                      let wire = try? JSONDecoder().decode(WireMessage.self, from: bytes) else { return }
                onEvent(.message(wire.message))
            case "feedback":
                let wire = event["feedback"]
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { try? JSONDecoder().decode(WireFeedback.self, from: $0) }
                onEvent(.feedback(wire?.feedback))
            default:
                return
            }
        }
    }

    private func send(_ command: [String: String], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }
}

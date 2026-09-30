import Combine
import Foundation

/// One visitor's conversation with the agent, as observable state. It draws
/// nothing: bind `messages`, `isTyping` and `status` to your own views and
/// call `send`.
///
///     @StateObject private var chat = VatioChat(vatio)
///
///     ForEach(chat.messages) { message in Bubble(message) }
///     if chat.isTyping { TypingDots() }
///     Button("Send") { Task { try await chat.send(text) } }
///
/// Creating one costs nothing and opens no connection. The conversation starts
/// on the first `send`, so a visitor who never writes never becomes a contact.
/// Call `resume()` when the view appears to pick up where they left off.
@MainActor
public final class VatioChat: ObservableObject {
    public enum Status: Sendable, Equatable {
        /// No conversation yet, or it was closed with `startOver()`.
        case idle
        case connecting
        /// Live: replies arrive the moment they are sent.
        case connected
        /// The socket dropped. Replies are fetched by polling until it is back.
        case reconnecting
        case closed
    }

    /// The conversation so far, oldest first, deduplicated by id.
    @Published public private(set) var messages: [VatioMessage] = []
    /// The agent is writing.
    @Published public private(set) var isTyping = false
    @Published public private(set) var status: Status = .idle
    /// The last failure that happened outside a `send` call — a reply that
    /// could not be fetched, a credential that expired. `send` throws instead.
    @Published public private(set) var lastError: VatioError?
    /// A moment to ask the visitor how it went, when Vatio offers one -- at
    /// most once per conversation, after a request looks resolved. Show it
    /// while `isOpen`, and answer with `rate` or `dismissFeedback`. It goes
    /// back to nil when the visitor writes again without answering.
    @Published public private(set) var feedback: VatioFeedback?

    /// The conversation id, once there is one.
    public var conversationID: Int? { current?.chatID }

    public let vatio: Vatio
    public let visitorToken: String?
    public let replyStyle: ReplyStyle

    private var current: VisitorStorage.StoredChat?
    private var starting: Task<VisitorStorage.StoredChat, Error>?
    private var cable: Cable?
    private var subscribed = false
    private var closed = false
    private var attempt = 0
    private var lastMessageID = 0
    private var nextPendingID = -1
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var pollTask: Task<Void, Never>?
    private var pollUntil = Date.distantPast

    private static let reconnectDelays: [Double] = [0.5, 1, 2, 5, 10]
    private static let pollInterval: UInt64 = 1_500_000_000
    private static let pollWindow: TimeInterval = 45
    private static let subscribeTimeout: UInt64 = 10_000_000_000

    /// `visitorToken` says who the visitor is when your app already knows:
    /// a token your backend signed for the signed-in user (see
    /// docs.vatio.ai/authentication/sessions). A different token subject is a
    /// different person, with a conversation of their own.
    ///
    /// `replyStyle` is fixed when the conversation starts.
    public init(_ vatio: Vatio, visitorToken: String? = nil, replyStyle: ReplyStyle = .stream) {
        self.vatio = vatio
        self.visitorToken = visitorToken
        self.replyStyle = replyStyle
    }

    // MARK: - Public surface

    /// Whether there is a stored, unexpired conversation `resume()` would open.
    public var canResume: Bool {
        let storage = vatio.storage(visitorToken)
        return storage.chat != nil || (storage.isIdentified && storage.anonymousChat != nil)
    }

    /// Reopens the visitor's stored conversation and loads its history. Does
    /// nothing when there is none — it never starts a new one.
    public func resume() async {
        guard current == nil, starting == nil, canResume else { return }
        do {
            _ = try await ensureStarted(createIfMissing: false)
        } catch let error as VatioError {
            lastError = error
        } catch {}
    }

    /// Sends the visitor's message. It appears in `messages` at once, marked
    /// `isPending`, and the reply follows through `messages` and `isTyping`.
    ///
    /// `attachments` adds up to four files (see `VatioUpload`); with them,
    /// `text` may be empty. Once the server answers, the pending message is
    /// replaced by the stored one, file URLs included. A voice note is
    /// transcribed in the background: the message shows "Audio"
    /// (`isMediaLabel`) at first, and its `content` becomes the transcript a
    /// few seconds later, in place.
    ///
    /// The first call starts the conversation. Throws `blank_content`,
    /// `content_too_long` (4,000 characters), `too_many_files`,
    /// `file_too_large`, `unsupported_file_type`, `rate_limited`,
    /// `origin_not_allowed`, …; on failure the pending message is removed, so
    /// put the text and files back.
    public func send(_ text: String = "", attachments: [VatioUpload] = []) async throws {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else {
            throw VatioError(code: "blank_content", message: "content or attachments are required")
        }
        guard attachments.count <= 4 else {
            throw VatioError(code: "too_many_files", message: "at most 4 files per message")
        }
        if let large = attachments.first(where: { $0.data.count > VatioUpload.maxBytes }) {
            throw VatioError(code: "file_too_large", message: "\(large.filename) is over 8 MB")
        }

        let pendingFiles = attachments.enumerated().map { index, file in
            VatioAttachment(
                id: -(index + 1), filename: file.filename, contentType: file.contentType,
                byteSize: file.data.count, kind: file.kind, url: nil
            )
        }
        let pending = VatioMessage(
            id: nextPendingID, role: .user, content: content, createdAt: Date(), isPending: true,
            attachments: pendingFiles, isMediaLabel: content.isEmpty
        )
        nextPendingID -= 1
        messages.append(pending)
        lastError = nil

        do {
            let chat = try await ensureStarted(createIfMissing: true)
            await ready()

            let data = attachments.isEmpty
                ? try await vatio.request(
                    "POST", "chats/\(chat.chatID)/messages", bearer: chat.chatToken, body: ["content": content]
                )
                : try await vatio.upload(
                    "chats/\(chat.chatID)/messages", bearer: chat.chatToken, content: content, files: attachments
                )
            let result = try? JSONDecoder().decode(WireSendResult.self, from: data)

            confirm(pending, as: result?.message?.message, id: result?.user_message_id)
            // Writing again moves the conversation on, and the moment with it.
            if feedback?.rating == nil { feedback = nil }
            if !subscribed { pollFor(Self.pollWindow) }
        } catch {
            messages.removeAll { $0.id == pending.id }
            throw error
        }
    }

    /// Answers the feedback moment. `comment` (up to 2,000 characters) is
    /// meant for `.neutral` and `.bad`. Throws `feedback_unavailable` once the
    /// moment has passed.
    public func rate(_ rating: VatioFeedback.Rating, comment: String? = nil) async throws {
        try await answerFeedback(rating: rating, comment: comment)
    }

    /// Declines the feedback moment; it is not offered again.
    public func dismissFeedback() async throws {
        try await answerFeedback(dismiss: true)
    }

    /// Switches to one of the visitor's past conversations, from
    /// `vatio.conversations()`. It becomes the stored one, so `resume()`
    /// returns to it from then on.
    public func open(_ conversation: VatioConversation) async throws {
        disconnect()
        messages = []
        let chat = VisitorStorage.StoredChat(
            chatID: conversation.id, chatToken: conversation.chatToken, expiresAt: conversation.expiresAt
        )
        vatio.storage(visitorToken).chat = chat
        try await connect(to: chat, loadHistory: true)
    }

    /// Forgets the stored conversation and clears `messages`. The next `send`
    /// starts a new one. Server history is kept.
    public func startOver() {
        disconnect()
        vatio.storage(visitorToken).chat = nil
        messages = []
        lastError = nil
        status = .idle
    }

    /// Disconnects. Call it when the conversation leaves the screen for good;
    /// `resume()` or `send` reconnects.
    public func close() {
        disconnect()
        status = .closed
    }

    // MARK: - Starting

    private func ensureStarted(createIfMissing: Bool) async throws -> VisitorStorage.StoredChat {
        if let current { return current }
        if let starting { return try await starting.value }

        let task = Task { try await self.start(createIfMissing: createIfMissing) }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func start(createIfMissing: Bool) async throws -> VisitorStorage.StoredChat {
        try vatio.validateToken()
        status = .connecting
        let storage = vatio.storage(visitorToken)

        if let stored = storage.chat ?? (storage.isIdentified ? storage.anonymousChat : nil) {
            if let visitorToken, !(try await identify(stored, visitorToken)) {
                // The stored conversation belongs to someone else.
                storage.anonymousChat = nil
            } else {
                // Signing in keeps the conversation the visitor was having.
                if storage.chat == nil {
                    storage.chat = stored
                    storage.anonymousChat = nil
                }
                try await connect(to: stored, loadHistory: true)
                return stored
            }
        }

        guard createIfMissing else {
            status = .idle
            throw VatioError(code: "no_conversation", message: "there is no conversation to resume")
        }

        var body: [String: Any] = ["reply_style": replyStyle.rawValue]
        if let ref = storage.visitorRef { body["visitor_ref"] = ref }
        if let visitorToken { body["visitor_token"] = visitorToken }

        let data = try await vatio.request("POST", "chats", bearer: vatio.token, body: body)
        let wire = try vatio.decode(WireChat.self, data)
        let chat = VisitorStorage.StoredChat(
            chatID: wire.chat_id, chatToken: wire.chat_token, expiresAt: parseDate(wire.chat_token_expires_at)
        )
        if let ref = wire.visitor_ref { storage.visitorRef = ref }
        storage.chat = chat

        try await connect(to: chat, loadHistory: false)
        return chat
    }

    /// False only when the server says this conversation belongs to a
    /// different person. A network failure carries on with it.
    private func identify(_ chat: VisitorStorage.StoredChat, _ visitorToken: String) async throws -> Bool {
        do {
            let data = try await vatio.request(
                "POST", "chats/\(chat.chatID)/identify", bearer: chat.chatToken, body: ["visitor_token": visitorToken]
            )
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return body?["reason"] as? String != "identity_changed"
        } catch let error as VatioError {
            return error.status != 401
        }
    }

    private func connect(to chat: VisitorStorage.StoredChat, loadHistory: Bool) async throws {
        closed = false
        status = .connecting
        if loadHistory {
            let data = try await vatio.request("GET", "chats/\(chat.chatID)/messages", bearer: chat.chatToken)
            merge(try vatio.decode(WireList<WireMessage>.self, data).data?.map(\.message) ?? [])
        }
        current = chat
        openSocket()
        await ready()
    }

    // MARK: - Transport

    private func openSocket() {
        guard let chat = current, !closed else { return }
        var components = URLComponents(url: vatio.baseURL.appendingPathComponent("cable"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"

        let cable = Cable(
            url: components.url!, origin: vatio.origin, chatToken: chat.chatToken, session: vatio.session, owner: self
        ) {
            [weak self] event in self?.handle(event)
        }
        self.cable = cable
        cable.connect()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.subscribeTimeout)
            guard let self, self.cable === cable, !self.subscribed else { return }
            // No socket in time (a network that eats upgrades): poll instead.
            self.pollFor(Self.pollWindow)
            self.releaseWaiters()
        }
    }

    private func handle(_ event: Cable.Event) {
        switch event {
        case .subscribed:
            subscribed = true
            attempt = 0
            status = .connected
            stopPolling()
            releaseWaiters()
            // Whatever was said while there was no subscription: the gap
            // after loading history, or a reconnect.
            if lastMessageID > 0 { Task { await resync() } }
            // A moment offered while nobody was listening arrives this way.
            Task { await refreshFeedback() }

        case .rejected:
            // The credential expired or was revoked. The next send starts a
            // new conversation.
            cable = nil
            subscribed = false
            current = nil
            vatio.storage(visitorToken).chat = nil
            status = .idle
            lastError = VatioError(code: "subscription_rejected", message: "the chat credential is no longer valid")
            releaseWaiters()

        case .typing(let typing):
            isTyping = typing

        case .message(let message):
            if message.role != .user { isTyping = false }
            merge([message])

        case .feedback(let offered):
            feedback = offered

        case .updated(let id, let content, let isMediaLabel):
            // A voice note's transcript, in where the "Audio" label stood.
            guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
            let old = messages[index]
            messages[index] = VatioMessage(
                id: old.id, role: old.role, content: content, createdAt: old.createdAt,
                attachments: old.attachments, isMediaLabel: isMediaLabel
            )

        case .closed:
            cable = nil
            subscribed = false
            guard !closed else { return }
            status = .reconnecting
            releaseWaiters()
            pollFor(Self.pollWindow)

            let delay = Self.reconnectDelays[min(attempt, Self.reconnectDelays.count - 1)]
            attempt += 1
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !self.closed, self.cable == nil else { return }
                self.openSocket()
            }
        }
    }

    /// Returns once the socket is subscribed, or once it is clear it will not
    /// be soon, so a send never races the reply it is about to cause.
    private func ready() async {
        guard cable != nil, !subscribed, pollTask == nil else { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func releaseWaiters() {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func disconnect() {
        closed = true
        cable?.close()
        cable = nil
        subscribed = false
        current = nil
        isTyping = false
        feedback = nil
        stopPolling()
        releaseWaiters()
    }

    // MARK: - Feedback

    private func answerFeedback(
        rating: VatioFeedback.Rating? = nil, comment: String? = nil, dismiss: Bool = false
    ) async throws {
        guard let chat = current else {
            throw VatioError(code: "feedback_unavailable", message: "there is no conversation")
        }
        var body: [String: Any] = [:]
        if let rating { body["rating"] = rating.rawValue }
        if let comment { body["comment"] = comment }
        if dismiss { body["dismiss"] = true }
        let data = try await vatio.request("POST", "chats/\(chat.chatID)/feedback", bearer: chat.chatToken, body: body)
        feedback = try vatio.decode(WireFeedbackEnvelope.self, data).feedback?.feedback
    }

    private func refreshFeedback() async {
        guard let chat = current,
              let data = try? await vatio.request("GET", "chats/\(chat.chatID)/feedback", bearer: chat.chatToken),
              let envelope = try? vatio.decode(WireFeedbackEnvelope.self, data),
              current?.chatID == chat.chatID else { return }
        let offered = envelope.feedback?.feedback
        if offered != feedback { feedback = offered }
    }

    // MARK: - Fallbacks

    private func resync() async {
        guard let chat = current else { return }
        do {
            let data = try await vatio.request(
                "GET", "chats/\(chat.chatID)/messages?after=\(lastMessageID)", bearer: chat.chatToken
            )
            let fetched = try vatio.decode(WireList<WireMessage>.self, data).data?.map(\.message) ?? []
            if fetched.contains(where: { $0.role != .user }) { isTyping = false }
            merge(fetched)
        } catch let error as VatioError {
            if error.code != "network_error" { lastError = error }
        } catch {}
    }

    private func pollFor(_ duration: TimeInterval) {
        pollUntil = max(pollUntil, Date().addingTimeInterval(duration))
        guard pollTask == nil, !closed else { return }

        pollTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                if self.closed || self.subscribed || Date() > self.pollUntil { break }
                await self.resync()
            }
            self?.pollTask = nil
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - State

    // The stored message when the server returned it (its transcript, its
    // file URLs); otherwise the pending one under the server's id.
    private func confirm(_ pending: VatioMessage, as stored: VatioMessage?, id: Int?) {
        guard let index = messages.firstIndex(where: { $0.id == pending.id }) else { return }
        guard let id = stored?.id ?? id, !messages.contains(where: { $0.id == id }) else {
            messages.remove(at: index)
            return
        }
        messages[index] = stored ?? VatioMessage(
            id: id, role: .user, content: pending.content, createdAt: pending.createdAt,
            attachments: pending.attachments, isMediaLabel: pending.isMediaLabel
        )
        lastMessageID = max(lastMessageID, id)
        sort()
    }

    private func merge(_ incoming: [VatioMessage]) {
        guard !incoming.isEmpty else { return }
        var known = Set(messages.map(\.id))
        for message in incoming where !known.contains(message.id) {
            // A resync can return the visitor's message before `send` hears
            // back: it replaces the pending copy instead of doubling it.
            if message.role == .user,
               let index = messages.firstIndex(where: { $0.isPending && $0.content == message.content }) {
                messages.remove(at: index)
            }
            messages.append(message)
            known.insert(message.id)
            lastMessageID = max(lastMessageID, message.id)
        }
        sort()
    }

    // Pending messages last, in the order they were sent (their ids count
    // down from -1).
    private func sort() {
        messages.sort { a, b in
            if a.isPending != b.isPending { return b.isPending }
            return a.isPending ? a.id > b.id : a.id < b.id
        }
    }
}

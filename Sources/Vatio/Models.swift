import Foundation
import UniformTypeIdentifiers

/// One message in a conversation, as the visitor sees it.
public struct VatioMessage: Identifiable, Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        case user
        case assistant
        /// A role this SDK version does not know yet, passed through as sent.
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "user": self = .user
            case "assistant": self = .assistant
            default: self = .other(raw)
            }
        }
    }

    /// Server id. Negative while `isPending`, because the server has not
    /// assigned one yet.
    public let id: Int
    public let role: Role
    /// Markdown, as the agent wrote it. Render it as untrusted text.
    public let content: String
    public let createdAt: Date?
    /// True for a message the visitor just sent that the server has not
    /// acknowledged yet. It is shown straight away so the question is on
    /// screen before the network answers.
    public let isPending: Bool
    /// The visitor's own files. While `isPending` their `url` is nil.
    public let attachments: [VatioAttachment]
    /// `content` is only a stand-in ("Image", "Audio") for a message that was
    /// just a file: draw the attachment, not the word.
    public let isMediaLabel: Bool

    public var isFromVisitor: Bool { role == .user }

    public init(
        id: Int, role: Role, content: String, createdAt: Date? = nil, isPending: Bool = false,
        attachments: [VatioAttachment] = [], isMediaLabel: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isPending = isPending
        self.attachments = attachments
        self.isMediaLabel = isMediaLabel
    }
}

/// A file on a message.
public struct VatioAttachment: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case image, audio, video, file
    }

    public let id: Int
    public let filename: String
    public let contentType: String
    public let byteSize: Int
    public let kind: Kind
    /// Absolute and signed; loads without the chat credential. Nil while the
    /// message is pending.
    public let url: URL?
}

/// A file to attach to `send`: an image (JPEG, PNG, WebP, GIF, HEIC), a PDF,
/// a text file, or audio (M4A, MP3, OGG, WAV, AAC, FLAC), up to 8 MB. A voice
/// note is transcribed, and the transcript becomes the message's content.
public struct VatioUpload: Sendable {
    public static let maxBytes = 8 * 1024 * 1024

    public let data: Data
    public let filename: String
    public let contentType: String

    public init(data: Data, filename: String, contentType: String) {
        self.data = data
        self.filename = filename
        self.contentType = contentType
    }

    /// Reads a local file, taking its type from the extension -- an
    /// `AVAudioRecorder` .m4a, a photo exported to disk, a picked PDF.
    public init(fileURL: URL) throws {
        let type = UTType(filenameExtension: fileURL.pathExtension)
        self.init(
            data: try Data(contentsOf: fileURL),
            filename: fileURL.lastPathComponent,
            contentType: type?.preferredMIMEType ?? "application/octet-stream"
        )
    }

    var kind: VatioAttachment.Kind {
        if contentType.hasPrefix("image/") { return .image }
        if contentType.hasPrefix("audio/") { return .audio }
        if contentType.hasPrefix("video/") { return .video }
        return .file
    }
}

/// How a reply is delivered. Fixed when a conversation starts.
public enum ReplyStyle: String, Sendable {
    /// One complete reply, sent the moment it is ready. The default.
    case stream
    /// Two or three short messages, each preceded by a typing indicator.
    case paced
    /// One complete reply and no typing events.
    case instant
}

/// The agent's public branding and the widget copy configured in `vatio.yml`.
public struct VatioConfig: Sendable {
    public let workspace: String
    public let environment: String
    public let agentName: String
    public let avatarURL: URL?
    public let about: String?
    /// `#RRGGBB`.
    public let accentColor: String?
    public let title: String?
    public let greeting: String?
    public let suggestions: [String]
    /// `en`, `es` or `pt`: the language for your UI's own labels. The agent
    /// answers in whatever language the visitor writes.
    public let locale: String?
}

/// A past conversation of this visitor, as returned by `Vatio.conversations`.
public struct VatioConversation: Identifiable, Hashable, Sendable {
    public let id: Int
    /// What the visitor opened with.
    public let title: String
    /// The last thing said.
    public let preview: String
    public let startedAt: Date?
    public let updatedAt: Date?

    let chatToken: String
    let expiresAt: Date?
}

/// A moment to ask the visitor how it went, offered by Vatio once per
/// conversation when a request looks resolved.
public struct VatioFeedback: Hashable, Sendable {
    public enum Rating: String, Sendable, CaseIterable {
        case good, neutral, bad
    }

    /// The agent that answered, for "How did <name> do?".
    public let agentName: String
    /// The reply the moment is attached to.
    public let messageID: Int
    /// The agent's own words to ask with, written for this conversation.
    /// nil when there are none; ask in your own words then.
    public let question: String?
    /// Set once the visitor answered.
    public let rating: Rating?
    public let submittedAt: Date?
    public let dismissed: Bool

    /// Still waiting for the visitor: neither rated nor dismissed.
    public var isOpen: Bool { rating == nil && !dismissed }
}

public struct VatioError: LocalizedError, Sendable, Equatable {
    /// Machine-readable: `origin_not_allowed`, `rate_limited`,
    /// `no_agent_deployed`, `blank_content`, `content_too_long`, … or
    /// `network_error` when the request never got an answer.
    public let code: String
    public let message: String
    /// HTTP status, when there was a response.
    public let status: Int?

    public init(code: String, message: String, status: Int? = nil) {
        self.code = code
        self.message = message
        self.status = status
    }

    public var errorDescription: String? { message }
}

// MARK: - Wire shapes

struct WireMessage: Decodable {
    let id: Int
    let role: String
    let content: String?
    let created_at: String?
    let occurred_at: String?
    let attachments: [WireAttachment]?
    let content_is_media_label: Bool?

    var message: VatioMessage {
        VatioMessage(
            id: id,
            role: .init(role),
            content: content ?? "",
            createdAt: parseDate(occurred_at ?? created_at),
            attachments: (attachments ?? []).map(\.attachment),
            isMediaLabel: content_is_media_label ?? false
        )
    }
}

struct WireAttachment: Decodable {
    let id: Int
    let filename: String
    let content_type: String?
    let byte_size: Int?
    let kind: String?
    let url: String?

    var attachment: VatioAttachment {
        VatioAttachment(
            id: id,
            filename: filename,
            contentType: content_type ?? "application/octet-stream",
            byteSize: byte_size ?? 0,
            kind: kind.flatMap(VatioAttachment.Kind.init(rawValue:)) ?? .file,
            url: url.flatMap(URL.init(string:))
        )
    }
}

struct WireSendResult: Decodable {
    let user_message_id: Int?
    let message: WireMessage?
}

struct WireFeedback: Decodable {
    let agent_name: String
    let message_id: Int
    let question: String?
    let rating: String?
    let submitted_at: String?
    let dismissed: Bool?

    var feedback: VatioFeedback {
        VatioFeedback(
            agentName: agent_name,
            messageID: message_id,
            question: question,
            rating: rating.flatMap(VatioFeedback.Rating.init(rawValue:)),
            submittedAt: parseDate(submitted_at),
            dismissed: dismissed ?? false
        )
    }
}

struct WireFeedbackEnvelope: Decodable {
    let feedback: WireFeedback?
}

struct WireList<T: Decodable>: Decodable {
    let data: [T]?
}

struct WireChat: Decodable {
    let chat_id: Int
    let chat_token: String
    let chat_token_expires_at: String?
    let visitor_ref: String?
}

struct WireConversation: Decodable {
    let chat_id: Int
    let chat_token: String
    let chat_token_expires_at: String?
    let title: String?
    let preview: String?
    let started_at: String?
    let updated_at: String?

    var conversation: VatioConversation {
        VatioConversation(
            id: chat_id,
            title: title ?? "",
            preview: preview ?? "",
            startedAt: parseDate(started_at),
            updatedAt: parseDate(updated_at),
            chatToken: chat_token,
            expiresAt: parseDate(chat_token_expires_at)
        )
    }
}

struct WireConfig: Decodable {
    struct Agent: Decodable {
        let name: String?
        let avatar_url: String?
        let about: String?
    }
    struct Theme: Decodable { let accent: String? }
    struct UI: Decodable {
        let title: String?
        let greeting: String?
        let suggestions: [String]?
    }

    let workspace: String
    let environment: String
    let agent: Agent
    let theme: Theme?
    let ui: UI?
    let locale: String?

    var config: VatioConfig {
        VatioConfig(
            workspace: workspace,
            environment: environment,
            agentName: agent.name ?? workspace,
            avatarURL: agent.avatar_url.flatMap(URL.init(string:)),
            about: agent.about,
            accentColor: theme?.accent,
            title: ui?.title,
            greeting: ui?.greeting,
            suggestions: ui?.suggestions ?? [],
            locale: locale
        )
    }
}

func parseDate(_ string: String?) -> Date? {
    guard let string else { return nil }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
}

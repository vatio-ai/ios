import Foundation

/// A connection to one Vatio workspace, from an iOS app.
///
///     let vatio = Vatio(workspace: "acme", token: "vatpub_...")
///     let chat = VatioChat(vatio)
///     try await chat.send("hola")
///
/// `token` is a publishable token (`vatpub_…`), meant to ship inside your app.
/// It only works once the workspace allowlists the app: add
/// `ios-app://YOUR.BUNDLE.ID` to `allowed_origins` in `vatio.yml`.
/// A `vat_` token is a developer secret and must never ship in an app.
public struct Vatio: Sendable {
    public static let version = "0.4.1"

    public let workspace: String
    public let token: String
    public let baseURL: URL
    /// The bundle id sent as `Origin: ios-app://<appID>`. Defaults to
    /// `Bundle.main.bundleIdentifier`.
    public let appID: String

    /// Where the conversation and visitor id are kept: a `UserDefaults`
    /// suite, or the standard one when nil.
    public let storageSuite: String?

    let session: URLSession

    public init(
        workspace: String,
        token: String,
        baseURL: URL = URL(string: "https://vatio.ai")!,
        appID: String? = nil,
        storageSuite: String? = nil,
        session: URLSession = .shared
    ) {
        self.workspace = workspace
        self.token = token
        self.baseURL = baseURL
        self.appID = appID ?? Bundle.main.bundleIdentifier ?? "unknown"
        self.storageSuite = storageSuite
        self.session = session
    }

    var origin: String { "ios-app://\(appID.lowercased())" }

    /// The agent's name, avatar, accent color and widget copy, without
    /// starting a conversation. Throws `no_agent_deployed` when nothing is
    /// published to the token's environment.
    public func config() async throws -> VatioConfig {
        try validateToken()
        let data = try await request("GET", "config", bearer: token)
        return try decode(WireConfig.self, data).config
    }

    /// Every conversation this visitor has had on this workspace from this
    /// device, newest first. `[]` for a visitor who never talked here. Pass
    /// the same `visitorToken` you give `VatioChat`.
    public func conversations(visitorToken: String? = nil) async throws -> [VatioConversation] {
        try validateToken()
        guard let visitorRef = storage(visitorToken).visitorRef else { return [] }

        // A conversation this person had signed in is listed only alongside
        // their token.
        var request = try urlRequest("GET", "chats?visitor_ref=\(queryEscaped(visitorRef))", bearer: token)
        if let visitorToken, !visitorToken.isEmpty {
            request.setValue(visitorToken, forHTTPHeaderField: "Vatio-Visitor-Token")
        }
        let data = try await send(request)
        return (try decode(WireList<WireConversation>.self, data).data ?? []).map(\.conversation)
    }

    // MARK: - Internals

    func storage(_ visitorToken: String?) -> VisitorStorage {
        let defaults = storageSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        return VisitorStorage(defaults: defaults, prefix: "vatio:\(baseURL.absoluteString):\(workspace)", visitorToken: visitorToken)
    }

    func validateToken() throws {
        guard token.hasPrefix("vatpub_") else {
            throw VatioError(
                code: "wrong_token_kind",
                message: "token must be a publishable token (vatpub_...). A vat_ token is a developer secret and must never ship in an app."
            )
        }
    }

    func request(_ method: String, _ path: String, bearer: String, body: [String: Any]? = nil) async throws -> Data {
        var request = try urlRequest(method, path, bearer: bearer)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await send(request)
    }

    /// multipart/form-data: `content` and one `files[]` part per upload.
    func upload(_ path: String, bearer: String, content: String, files: [VatioUpload]) async throws -> Data {
        var request = try urlRequest("POST", path, bearer: bearer)
        let boundary = "vatio-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func part(_ headers: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\n\(headers)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        if !content.isEmpty {
            part("Content-Disposition: form-data; name=\"content\"", Data(content.utf8))
        }
        for file in files {
            let name = file.filename.replacingOccurrences(of: "\"", with: "")
            part(
                "Content-Disposition: form-data; name=\"files[]\"; filename=\"\(name)\"\r\nContent-Type: \(file.contentType)",
                file.data
            )
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return try await send(request)
    }

    private func urlRequest(_ method: String, _ path: String, bearer: String) throws -> URLRequest {
        let workspacePath = workspace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspace
        guard let url = URL(string: "api/visitor/v1/\(workspacePath)/\(path)", relativeTo: baseURL) else {
            throw VatioError(code: "sdk_error", message: "invalid URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VatioError(code: "network_error", message: error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw errorFrom(data, status: status) }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw VatioError(code: "invalid_response", message: "unexpected response from Vatio: \(error)")
        }
    }

    private func errorFrom(_ data: Data, status: Int) -> VatioError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = body?["error"] as? String
        let message = body?["error_description"] as? String ?? code ?? "request failed with \(status)"
        return VatioError(code: code ?? "request_failed", message: message, status: status)
    }
}

func queryEscaped(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

/// The stored conversation and visitor id, kept per person: a different
/// `visitorToken` subject is a different visitor, with its own conversation
/// and its own id, so signing out of the app really does sign out.
struct VisitorStorage {
    struct StoredChat: Codable {
        let chatID: Int
        let chatToken: String
        let expiresAt: Date?

        var isExpired: Bool { (expiresAt ?? .distantPast) <= Date() }
    }

    let defaults: UserDefaults
    let prefix: String
    let visitorToken: String?

    var isIdentified: Bool { subject != nil }

    var visitorRef: String? {
        get { defaults.string(forKey: key("visitor", identified: isIdentified)) }
        nonmutating set { defaults.set(newValue, forKey: key("visitor", identified: isIdentified)) }
    }

    var chat: StoredChat? {
        get { read(key("chat", identified: isIdentified)) }
        nonmutating set { write(newValue, key("chat", identified: isIdentified)) }
    }

    /// The conversation filed before the visitor signed in, which an
    /// identified visitor adopts instead of losing.
    var anonymousChat: StoredChat? {
        get { read(key("chat", identified: false)) }
        nonmutating set { write(newValue, key("chat", identified: false)) }
    }

    private func key(_ name: String, identified: Bool) -> String {
        let scope = identified ? "default#\(subject!)" : "default"
        return "\(prefix):\(scope):\(name)"
    }

    private func read(_ key: String) -> StoredChat? {
        guard let data = defaults.data(forKey: key),
              let chat = try? JSONDecoder().decode(StoredChat.self, from: data),
              !chat.isExpired else { return nil }
        return chat
    }

    private func write(_ chat: StoredChat?, _ key: String) {
        if let chat, let data = try? JSONEncoder().encode(chat) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // Read without verifying, which is safe because it is only a cache key:
    // the server checks the signature before trusting anything in it.
    private var subject: String? {
        guard let visitorToken else { return nil }
        let parts = visitorToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sub = payload["sub"] else { return nil }
        return "\(sub)"
    }
}

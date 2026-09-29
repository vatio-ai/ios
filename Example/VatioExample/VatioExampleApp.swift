import SwiftUI
import Vatio

// A dummy app for trying the SDK: a home screen with an ask bar at the
// bottom, a conversation tab where the agent answers, and a settings tab for
// the workspace and token. Allow `ios-app://ai.vatio.example` in the
// workspace's `widget.allowed_origins` first.
//
// Settings are UserDefaults, so they can also come from launch arguments:
//   xcrun simctl launch booted ai.vatio.example -workspace acme -token vatpub_...
// and `-ask "hola"` there, or opening `vatioexample://ask?q=hola`, asks a
// question the way the bar does.
@main
struct VatioExampleApp: App {
    @StateObject private var store = ChatStore()
    @State private var tab = Tab.home

    enum Tab { case home, conversation, settings }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                HomeView()
                    .safeAreaInset(edge: .bottom) {
                        AskBar { ask($0) }
                    }
                    .tabItem { Label("Inicio", systemImage: "house") }
                    .tag(Tab.home)

                ConversationView(store: store, chat: store.chat)
                    .id(ObjectIdentifier(store.chat))
                    .tabItem { Label("Asistente", systemImage: "bubble.left.and.bubble.right") }
                    .tag(Tab.conversation)

                SettingsView(store: store)
                    .tabItem { Label("Ajustes", systemImage: "gear") }
                    .tag(Tab.settings)
            }
            .task(id: ObjectIdentifier(store.chat)) {
                await store.chat.resume()
                store.settle(store.chat.messages)
            }
            .task {
                // Launch arguments live in UserDefaults' argument domain, so
                // this is only set for the launch that passed it.
                if let question = UserDefaults.standard.string(forKey: "ask") { ask(question) }
            }
            .onOpenURL { url in
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                if url.host == "ask", let question = query?.first(where: { $0.name == "q" })?.value {
                    ask(question)
                }
            }
        }
    }

    private func ask(_ question: String) {
        tab = .conversation
        store.send(question)
    }
}

/// Holds the current VatioChat and rebuilds it when the settings change.
@MainActor
final class ChatStore: ObservableObject {
    @AppStorage("workspace") var workspace = ""
    @AppStorage("token") var token = ""
    @AppStorage("baseURL") var baseURL = "https://vatio.ai"

    @Published private(set) var chat: VatioChat
    @Published var sendError: String?

    /// Replies already shown in full: history from `resume()`, and every
    /// reply once its typewriter finishes. Only the rest are painted.
    private(set) var settled: Set<Int> = []

    func settle(_ messages: [VatioMessage]) {
        settled.formUnion(messages.map(\.id))
        objectWillChange.send()
    }

    init() {
        chat = VatioChat(Vatio(workspace: "", token: ""))
        rebuild()
    }

    var isConfigured: Bool { !workspace.isEmpty && token.hasPrefix("vatpub_") }

    func rebuild() {
        chat.close()
        let url = URL(string: baseURL) ?? URL(string: "https://vatio.ai")!
        chat = VatioChat(Vatio(workspace: workspace, token: token, baseURL: url))
    }

    func send(_ question: String) {
        sendError = nil
        Task {
            do {
                try await chat.send(question)
            } catch let error as VatioError {
                sendError = "\(error.code): \(error.message)"
            } catch {
                sendError = error.localizedDescription
            }
        }
    }
}

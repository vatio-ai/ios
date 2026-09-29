import SwiftUI
import Vatio

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Tu app") {
                    Label("Pedidos", systemImage: "shippingbox")
                    Label("Pagos", systemImage: "creditcard")
                    Label("Perfil", systemImage: "person")
                }
                Section {
                    Text("Escribe una pregunta abajo: la app pasa a la pestaña Asistente y el agente responde ahí.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Inicio")
        }
    }
}

struct AskBar: View {
    var placeholder = "Pregúntale al asistente"
    var onSubmit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func submit() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        text = ""
        onSubmit(question)
    }
}

struct ConversationView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var chat: VatioChat

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if chat.messages.isEmpty {
                            Text(store.isConfigured ? "Todavía no hay conversación." : "Configura workspace y token en Ajustes.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                        }
                        ForEach(chat.messages) { message in
                            Bubble(
                                message: message,
                                paints: message.role == .assistant && !store.settled.contains(message.id),
                                onProgress: { proxy.scrollTo(message.id, anchor: .bottom) },
                                onFinish: { store.settle([message]) }
                            )
                            .id(message.id)
                        }
                        if let feedback = chat.feedback, feedback.isOpen || feedback.rating != nil {
                            FeedbackCard(chat: chat, feedback: feedback)
                                .id("feedback")
                                .onAppear { withAnimation { proxy.scrollTo("feedback", anchor: .bottom) } }
                        }
                        if chat.isTyping {
                            HStack {
                                ProgressView()
                                Text("Escribiendo…").font(.footnote).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .id("typing")
                        }
                        if let error = store.sendError ?? chat.lastError?.message {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
                .onChange(of: chat.messages.last?.id) { id in
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: chat.isTyping) { typing in
                    if typing { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                AskBar(placeholder: "Escribe un mensaje") { store.send($0) }
            }
            .navigationTitle("Asistente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    StatusDot(status: chat.status)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Nueva") { chat.startOver() }
                        .disabled(chat.messages.isEmpty)
                }
            }
        }
    }
}

struct Bubble: View {
    let message: VatioMessage
    var paints = false
    var onProgress: () -> Void = {}
    var onFinish: () -> Void = {}

    var body: some View {
        HStack {
            if message.isFromVisitor { Spacer(minLength: 40) }
            TypewriterText(text: message.content, paints: paints, onProgress: onProgress, onFinish: onFinish)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.isFromVisitor ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(message.isFromVisitor ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .opacity(message.isPending ? 0.6 : 1)
            if !message.isFromVisitor { Spacer(minLength: 40) }
        }
    }
}

struct StatusDot: View {
    let status: VatioChat.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .idle, .closed: return .gray
        }
    }

    private var label: String {
        switch status {
        case .idle: return "sin conversación"
        case .connecting: return "conectando"
        case .connected: return "en vivo"
        case .reconnecting: return "reconectando"
        case .closed: return "cerrado"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: ChatStore
    @State private var workspace = ""
    @State private var token = ""
    @State private var baseURL = ""
    @State private var agent: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("workspace (slug)", text: $workspace)
                    TextField("vatpub_…", text: $token)
                    TextField("https://vatio.ai", text: $baseURL)
                        .keyboardType(.URL)
                } header: {
                    Text("Workspace")
                } footer: {
                    Text("Agrega ios-app://\(Bundle.main.bundleIdentifier ?? "") a widget.allowed_origins en vatio.yml.")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section {
                    Button("Guardar y conectar") { apply() }
                    if let agent { Text(agent).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Ajustes")
            .onAppear {
                workspace = store.workspace
                token = store.token
                baseURL = store.baseURL
            }
        }
    }

    private func apply() {
        store.workspace = workspace.trimmingCharacters(in: .whitespaces)
        store.token = token.trimmingCharacters(in: .whitespaces)
        store.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        store.rebuild()
        agent = "Verificando…"
        Task {
            do {
                let config = try await store.chat.vatio.config()
                agent = "Conectado a \(config.agentName) (\(config.environment))"
            } catch let error as VatioError {
                agent = "\(error.code): \(error.message)"
            } catch {
                agent = error.localizedDescription
            }
        }
    }
}

/// Shows a reply that arrived whole as if it were being written, the way the
/// web widget does: the SDK delivers the complete message, and the effect is
/// purely on screen. Faster the more text is left, so a long answer never
/// keeps the reader waiting. Tap to show it all at once.
struct TypewriterText: View {
    let text: String
    let paints: Bool
    var onProgress: () -> Void = {}
    var onFinish: () -> Void = {}

    @State private var shown: Int

    init(text: String, paints: Bool, onProgress: @escaping () -> Void = {}, onFinish: @escaping () -> Void = {}) {
        self.text = text
        self.paints = paints
        self.onProgress = onProgress
        self.onFinish = onFinish
        _shown = State(initialValue: paints ? 0 : text.count)
    }

    var body: some View {
        Text(LocalizedStringKey(String(text.prefix(shown))))
            .onTapGesture { finish() }
            .onChange(of: paints) { paints in
                if !paints { shown = text.count }
            }
            .task(id: text) { await paint() }
    }

    private func paint() async {
        guard paints else { return }
        var last = Date()
        while shown < text.count {
            try? await Task.sleep(nanoseconds: 16_000_000)
            if Task.isCancelled || !paints { return }

            let now = Date()
            let elapsed = now.timeIntervalSince(last)
            last = now
            // Characters per second, as in the widget: behind / 0.4s, 170...900.
            let rate = min(900, max(170, Double(text.count - shown) / 0.4))
            shown = min(text.count, shown + max(1, Int((rate * elapsed).rounded())))
            onProgress()
        }
        onFinish()
    }

    private func finish() {
        guard shown < text.count else { return }
        shown = text.count
        onFinish()
    }
}

/// What Vatio's feedback moment looks like in this app. The SDK only says
/// when to ask (`chat.feedback`) and takes the answer (`rate`,
/// `dismissFeedback`); the card is yours to design.
struct FeedbackCard: View {
    @ObservedObject var chat: VatioChat
    let feedback: VatioFeedback

    @State private var picked: VatioFeedback.Rating?
    @State private var comment = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if feedback.rating != nil {
                Label("¡Gracias por tu opinión!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Text("¿Cómo lo hizo \(feedback.agentName)?").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Omitir") { answer { try await chat.dismissFeedback() } }
                        .font(.footnote)
                }
                HStack(spacing: 8) {
                    ForEach(VatioFeedback.Rating.allCases, id: \.self) { rating in
                        Button { choose(rating) } label: {
                            Text(label(rating)).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(picked == rating ? .accentColor : .secondary)
                    }
                }
                if let picked, picked != .good {
                    TextField("¿Qué pudo salir mejor? (opcional)", text: $comment, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button("Enviar") {
                        answer { try await chat.rate(picked, comment: comment.isEmpty ? nil : comment) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .disabled(sending)
    }

    private func label(_ rating: VatioFeedback.Rating) -> String {
        switch rating {
        case .good: return "Bien"
        case .neutral: return "Más o menos"
        case .bad: return "Mal"
        }
    }

    // "Bien" needs no explanation, so it goes straight out.
    private func choose(_ rating: VatioFeedback.Rating) {
        picked = rating
        if rating == .good { answer { try await chat.rate(.good) } }
    }

    private func answer(_ call: @escaping () async throws -> Void) {
        sending = true
        error = nil
        Task {
            do { try await call() } catch { self.error = (error as? VatioError)?.message ?? error.localizedDescription }
            sending = false
        }
    }
}

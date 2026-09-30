# Vatio for iOS

Talk to a [Vatio](https://vatio.ai) agent from your own iOS app. A Swift
package with no dependencies and no UI: it gives you the conversation as
observable state, and you draw it however your app looks.

- iOS 15+ (macOS 12+ also works)
- Swift Package Manager
- Foundation and Combine only

## Setup

**1. Allow your app.** A publishable token only works from origins the
workspace allowlists. Your app's origin is `ios-app://` plus its bundle id:

```yaml
# vatio.yml
allowed_origins:
  - https://acme.com
  - ios-app://com.acme.app
```

```bash
vatio push
vatio tokens create --env live --label ios
```

**2. Add the package** `https://github.com/urcalab/vatio-ios` in Xcode
(File → Add Package Dependencies…) or in `Package.swift`, and import `Vatio`:

```swift
.package(url: "https://github.com/urcalab/vatio-ios", from: "0.1.0")
```

**3. Create a client** with the `vatpub_` token. It is meant to ship inside
the app. A `vat_` token is a developer secret: never put one in an app.

```swift
import Vatio

let vatio = Vatio(workspace: "acme", token: "vatpub_...")
```

## The whole API

```swift
let chat = VatioChat(vatio)          // no network yet

chat.messages                        // [VatioMessage], oldest first
chat.isTyping                        // the agent is writing
chat.status                          // .idle .connecting .connected .reconnecting .closed
chat.lastError                       // background failures; send() throws instead
chat.feedback                        // a feedback moment on offer, or nil

try await chat.send("hola")          // starts the conversation on first call
try await chat.send(attachments: [upload])   // images, PDFs, text, audio (8 MB)
await chat.resume()                  // reopen the stored conversation, if any
chat.startOver()                     // forget it; next send starts a new one
chat.close()                         // disconnect

try await chat.rate(.good)           // answer it: .good .neutral .bad (+ comment:)
try await chat.dismissFeedback()     // or decline it

try await vatio.config()             // agent name, avatar, accent, greeting, suggestions
try await vatio.conversations()      // this visitor's past conversations
try await chat.open(conversation)    // switch to one of them
```

A `VatioMessage` has `id`, `role` (`.user`, `.assistant`), `content` (markdown,
untrusted), `createdAt` and `isPending`. The visitor's message appears in
`messages` the moment `send` is called, with `isPending == true` until the
server acknowledges it; the reply follows on its own.

## Example: a text bar that opens the conversation

A bar at the bottom of any screen. When the user asks something, the app moves
to a Conversation tab where the agent is answering.

```swift
import SwiftUI
import Vatio

@main
struct AcmeApp: App {
    @StateObject private var chat = VatioChat(Vatio(workspace: "acme", token: "vatpub_..."))
    @State private var tab = Tab.home

    enum Tab { case home, conversation }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                HomeView()
                    .safeAreaInset(edge: .bottom) {
                        AskBar { question in
                            tab = .conversation
                            Task { try? await chat.send(question) }
                        }
                    }
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag(Tab.home)

                ConversationView(chat: chat)
                    .tabItem { Label("Assistant", systemImage: "bubble.left.and.bubble.right") }
                    .tag(Tab.conversation)
            }
            .task { await chat.resume() }
        }
    }
}

struct AskBar: View {
    var onSubmit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            TextField("Ask anything", text: $text)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(submit)
            Button(action: submit) { Image(systemName: "arrow.up.circle.fill") }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func submit() {
        let question = text
        text = ""
        onSubmit(question)
    }
}

struct ConversationView: View {
    @ObservedObject var chat: VatioChat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.messages) { message in
                        Text(LocalizedStringKey(message.content))   // renders basic markdown
                            .padding(10)
                            .background(message.isFromVisitor ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .frame(maxWidth: .infinity, alignment: message.isFromVisitor ? .trailing : .leading)
                            .opacity(message.isPending ? 0.6 : 1)
                            .id(message.id)
                    }
                    if chat.isTyping {
                        ProgressView().id("typing")
                    }
                }
                .padding()
            }
            .onChange(of: chat.messages.last?.id) { id in
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            AskBar { question in Task { try? await chat.send(question) } }
        }
    }
}
```

Handle the error from `send` to put the text back in the field: on failure the
pending message is removed from `messages`.

### Try it: the example app

`Example/` is a runnable version of this, with a settings tab for the workspace,
token and base URL. It also paints each new reply progressively, as the web
widget does (`TypewriterText` in `Views.swift`): the SDK delivers the reply
whole, and the effect is purely on screen, so copy it if you want it. Allow `ios-app://ai.vatio.example` in `vatio.yml`, then:

```bash
open Example/VatioExample.xcodeproj    # ⌘R on a simulator
```

Or launch it already configured from the command line, with a question:

```bash
xcrun simctl launch booted ai.vatio.example \
  -workspace acme -token vatpub_... -baseURL http://localhost:3000 -ask "hola"
```

`project.yml` regenerates the project with `xcodegen generate`.

## Files and voice notes

`send(_:attachments:)` takes up to four `VatioUpload`s — an image (JPEG, PNG,
WebP, GIF, HEIC), a PDF, a text file, or audio (M4A, MP3, OGG, WAV, AAC, FLAC),
up to 8 MB each. With files, the text may be empty:

```swift
let photo = VatioUpload(data: jpegData, filename: "photo.jpg", contentType: "image/jpeg")
try await chat.send("Is this the right part?", attachments: [photo])

// An AVAudioRecorder recording (AAC in .m4a) -- the type comes from the extension.
try await chat.send(attachments: [try VatioUpload(fileURL: recordingURL)])
```

The pending message shows the files at once, with `url == nil`; when the
server answers it is replaced by the stored message, whose `VatioAttachment`s
each have a signed, absolute `url`. A voice note is transcribed in the
background: the message reads "Audio" at first and its `content` becomes the
transcript a few seconds later, in place. The agent waits for it. When `isMediaLabel` is true, `content` is only a stand-in
("Image", "Audio") for a file-only message: draw the attachment instead.

The server reads a file's type from its bytes and refuses one the agent cannot
read (`unsupported_file_type`). `Example/` has a composer with a photo picker
and a voice recorder (`Composer`, `VoiceRecorder`, `AttachmentView` in
`Views.swift`); recording needs `NSMicrophoneUsageDescription` in your
Info.plist.

## Visitor feedback

Vatio offers a feedback moment at most once per conversation, when a request
looks resolved and the visitor closed the topic. `chat.feedback` holds it —
pushed the moment it exists, and fetched on connect for a conversation that
was resumed. Show your own prompt while `feedback.isOpen` and answer with
`rate(_:comment:)` (a comment of up to 2,000 characters, meant for `.neutral`
and `.bad`) or `dismissFeedback()`. It goes back to nil when the visitor writes
again without answering. `Example/` has a card for it (`FeedbackCard`).

## Signed-in users

When your app knows who the user is, have your backend sign a visitor token
and pass it, so the agent can use protected tools and the conversation lands on
the right contact:

```swift
let chat = VatioChat(vatio, visitorToken: tokenFromYourBackend)
```

Pass the same token to `vatio.conversations(visitorToken:)`. A different token
subject is a different person, with its own conversation and history, so
signing out of your app signs out of the chat too. An anonymous conversation is
kept when the user signs in. See
[Sessions and channels](https://docs.vatio.ai/authentication/sessions).

## Options

```swift
Vatio(
    workspace: "acme",
    token: "vatpub_...",
    baseURL: URL(string: "https://vatio.ai")!,   // default
    appID: nil,               // defaults to Bundle.main.bundleIdentifier
    storageSuite: nil,        // UserDefaults suite; standard when nil
    session: .shared          // URLSession
)

VatioChat(vatio, visitorToken: nil, replyStyle: .stream)   // .stream, .paced, .instant
```

`replyStyle` is fixed when a conversation starts. `.stream` sends one complete
reply as soon as it is ready; `.paced` sends two or three short messages with a
typing indicator before each, like a person texting.

## Delivery and storage

Replies arrive over a WebSocket. When it drops (the app went to the
background, the network changed), the SDK reconnects with backoff, polls in the
meantime, and fetches whatever was said while it was away. Messages are
deduplicated by id.

The current conversation and the visitor id are stored in `UserDefaults`, per
workspace and per signed-in user. Chat credentials last 12 hours; after that,
`resume()` finds nothing and the next `send` starts a new conversation.

Limits are the same as on the web: 4,000 characters per message, and per IP
and workspace, per minute, 10 conversations started, 30 messages and 60
configuration reads or conversation lists.

## Errors

Every failure is a `VatioError` with a `code`, a `message` and the HTTP
`status` when there was one:

| `code` | Meaning |
|---|---|
| `origin_not_allowed` | `ios-app://<bundle id>` is not in `allowed_origins` |
| `wrong_token_kind` | The token is not a `vatpub_` publishable token |
| `no_agent_deployed` | Nothing is published to the token's environment |
| `blank_content`, `content_too_long` | The message is empty or over 4,000 characters |
| `too_many_files`, `file_too_large`, `unsupported_file_type` | More than four files, one over 8 MB, or a type the agent cannot read |
| `rate_limited` | Too many requests; back off |
| `subscription_rejected` | The chat credential expired; the next `send` starts a new conversation |
| `network_error` | The request never got an answer |

## Versions

Tags follow semver, and `Vatio.version` matches the tag. A breaking change to
the public API is a new major version, so `from: "0.1.0"` never moves you to
one by surprise.

This repository is published from the one Vatio is built in, so changes land
there first. Report a problem at <https://vatio.ai> or with `vatio issue`.

# LocalHubClient (Swift)

SwiftPM package for iOS 17+ and macOS 14+. Pairing by QR invite, SHA-256 certificate pinning answered before any
request bytes are sent, Keychain session storage, chat (+ streaming), embeddings, images, audio, transcription,
video, 3D, files, jobs (events, previews, cancel), typed errors and Bonjour discovery with automatic relocation.

```swift
import LocalHubClient

let hub = HubClient(store: KeychainSessionStore())
try await hub.restore()
try await hub.pair(try HubInvite(scannedText), deviceName: "iPad", app: "my-app", scopes: ["chat", "image.edit"])
let reply = try await hub.chat(ChatRequest(model: "lmstudio/qwen/qwen3-8b", messages: [.user("Merhaba")]))
```

iOS apps need `NSLocalNetworkUsageDescription` (and `NSBonjourServices` = `_localhub._tcp` for discovery).
Tests run against the real hub server from the hub package: `cd ../../hub && swift test --filter SwiftSDKTests`.
See [Integrate a client](../../README.md#integrate-a-client) and the [OpenAPI specification](../../api/openapi.yaml).

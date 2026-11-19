import Foundation
import LocalHubClient

// The app's Playground uses the Swift SDK. Both modules name things HubJob/HubFile, so the SDK is
// only imported here and in PlaygroundView.
typealias PlaygroundClient = LocalHubClient.HubClient
typealias PlaygroundModel = LocalHubClient.HubModel

func makePlaygroundClient(address: URL, fingerprint: String, token: String, deviceID: String, scopes: [String],
                          hubID: String, hubName: String) async throws -> PlaygroundClient {
    let store = LocalHubClient.MemorySessionStore()
    await store.save(HubSession(address: address, fingerprint: fingerprint, token: token, deviceID: deviceID,
        scopes: scopes, hubID: hubID, hubName: hubName))
    let client = HubClient(store: store)
    try await client.restore()
    return client
}

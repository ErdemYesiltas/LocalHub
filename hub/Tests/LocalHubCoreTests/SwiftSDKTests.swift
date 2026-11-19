import Foundation
import LocalHubClient
import Vapor
import XCTest
@testable import LocalHubCore

/// The Swift SDK (`clients/swift`) against the real hub server, with fake LM Studio and ComfyUI behind it.
final class SwiftSDKTests: XCTestCase, @unchecked Sendable {
    private var lmStudio: Application!
    private var comfy: Application!
    private var server: HubServer!
    private var core: HubCore!
    private var directory: URL!
    private var port = 0

    override func setUp() async throws {
        directory = try temporaryDirectory()
        lmStudio = try await Application.make(.testing)
        lmStudio.get("v1", "models") { _ in Response(status: .ok, body: .init(string: #"{"data": [{"id": "qwen"}]}"#)) }
        lmStudio.post("v1", "chat", "completions") { request -> Response in
            let body = try JSONSerialization.jsonObject(with: Data(request.body.data!.readableBytesView)) as! [String: Any]
            if body["stream"] as? Bool == true {
                return Response(status: .ok, headers: ["Content-Type": "text/event-stream"], body: .init(string:
                    "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Mer\"}}]}\n\n"
                    + "data: {\"choices\":[{\"delta\":{\"content\":\"haba\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"))
            }
            return Response(status: .ok, body: .init(string: #"{"choices": [{"message": {"role": "assistant", "content": "Merhaba"}}]}"#))
        }
        try await lmStudio.server.start(address: .hostname("127.0.0.1", port: 0))
        comfy = try await Application.make(.testing)
        FakeComfy().routes(comfy)
        try await comfy.server.start(address: .hostname("127.0.0.1", port: 0))

        core = try HubCore(directory: directory)
        try core.integrations.save(ProviderConfiguration(id: "lmstudio", kind: .openai, name: "LM Studio",
            baseURL: "http://127.0.0.1:\(try XCTUnwrap(lmStudio.http.server.shared.localAddress?.port))"))
        try core.integrations.save(ProviderConfiguration(id: "ollama", kind: .openai, name: "Ollama", baseURL: "http://127.0.0.1:1"))
        try core.integrations.save(ProviderConfiguration(id: "comfyui", kind: .comfyui, name: "ComfyUI",
            baseURL: "http://127.0.0.1:\(try XCTUnwrap(comfy.http.server.shared.localAddress?.port))"))
        let json = try sample("sdxl-text-to-image.json")
        let detected = try WorkflowGraph(json: json).detectSlots()
        try core.integrations.save(WorkflowTemplate(id: "sdxl", name: "SDXL", integrationID: "comfyui", capability: .imageCreate,
            workflow: json, slots: detected.slots, outputNode: detected.outputNode))
        var settings = HubSettings()
        settings.minFreeMemoryGB = 0
        try core.store.save(settings)
        server = HubServer(core: core)
        try await server.start(settings: settings, portOverride: 0)
        let bound = await server.port
        port = try XCTUnwrap(bound)
    }

    override func tearDown() async throws {
        await server.stop()
        for app in [lmStudio!, comfy!] { await app.server.shutdown(); try await app.asyncShutdown() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func invite(fingerprint: String? = nil) async throws -> LocalHubClient.HubInvite {
        let window = await core.authority.openWindow()
        return try LocalHubClient.HubInvite(PairingInvite.uri(address: "https://127.0.0.1:\(port)",
            fingerprint: fingerprint ?? core.certificate.fingerprint, code: window.code, hubID: core.identity.id, hubName: "Test Mac"))
    }

    func testPairChatStreamAndErrors() async throws {
        let store = LocalHubClient.MemorySessionStore()
        let client = HubClient(store: store)
        let session = try await client.pair(try await invite(), deviceName: "iPad", app: "swift-tests")
        XCTAssertEqual(session.hubName, "Test Mac")
        let saved = try await store.load()
        XCTAssertEqual(saved?.token, session.token)

        let restored = HubClient(store: store)
        try await restored.restore()
        let models = try await restored.models()
        XCTAssertEqual(models.map(\.id), ["lmstudio/qwen", "comfyui/sdxl"])
        let reply = try await restored.chat(ChatRequest(model: "lmstudio/qwen", messages: [.user("Merhaba")]))
        XCTAssertEqual(reply, "Merhaba")

        var text = "", thinking = ""
        for try await delta in try await restored.chatStream(ChatRequest(model: "lmstudio/qwen", messages: [.user("hi")])) {
            text += delta.content
            thinking += delta.reasoning
        }
        XCTAssertEqual(text, "Merhaba")
        XCTAssertEqual(thinking, "hmm")

        do {
            _ = try await restored.chat(ChatRequest(model: "ollama/llama3", messages: [.user("hi")]))
            XCTFail("Ollama is not running")
        } catch let error as HubClientError {
            XCTAssertEqual(error.code, "provider_unavailable")
            XCTAssertEqual(error.errorDescription, "Ollama is not running on this Mac (http://127.0.0.1:1)")
        }

        try await restored.unpair()
        do { _ = try await restored.models(); XCTFail("Unpaired") } catch HubClientError.notPaired {}
    }

    func testWrongPinNeverReachesTheHub() async throws {
        let client = HubClient(store: LocalHubClient.MemorySessionStore())
        do {
            _ = try await client.pair(try await invite(fingerprint: String(repeating: "0", count: 64)), deviceName: "x", app: "t")
            XCTFail("Paired through a wrong pin")
        } catch HubClientError.pinMismatch {}
        let devices = await core.authority.listDevices()
        XCTAssertTrue(devices.isEmpty)
    }

    func testImagesJobsAndFiles() async throws {
        let client = HubClient(store: LocalHubClient.MemorySessionStore())
        try await client.pair(try await invite(), deviceName: "iPad", app: "swift-tests")
        let image = try await client.generateImage(prompt: "a fox", size: "512x512", extra: ["seed": 3])
        XCTAssertEqual(image.items.first?.data, tinyPNG)

        let job = try await client.startImage(prompt: "a boat")
        var states: [String] = []
        for try await update in await client.jobEvents(job.id) { states.append(update.status) }
        XCTAssertEqual(states.last, "completed")
        let finished = try await client.job(job.id)
        let recipe = try await client.recipe(job.id)
        XCTAssertEqual(recipe.parameters.prompt, "a boat")
        XCTAssertNotNil(recipe.parameters.seed)
        let replayed = try await client.replayJob(job.id, variation: true)
        XCTAssertTrue(replayed.has_recipe == true)
        for try await update in await client.jobEvents(replayed.id) { if update.isFinished { break } }
        let output = try await client.fileContent(try XCTUnwrap(finished.output_file_ids.first))
        XCTAssertEqual(output, tinyPNG)

        let uploaded = try await client.uploadFile(tinyPNG, filename: "ref.png", contentType: "image/png", purpose: "reference")
        XCTAssertEqual(uploaded.purpose, "reference")
        let files = try await client.files()
        XCTAssertEqual(files.count, 4)
        try await client.deleteFile(uploaded.id)
        let remaining = try await client.files()
        XCTAssertEqual(remaining.count, 3)
    }

    /// `LOCALHUB_LIVE=1 swift test --filter testLiveBonjourDiscovery` with a hub running on the LAN.
    func testLiveBonjourDiscovery() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOCALHUB_LIVE"] == "1", "needs a hub advertising on this network")
        let hubs = await discoverHubs(timeout: .seconds(3))
        print("discovered:", hubs.map { "\($0.name) \($0.host):\($0.port)" })
        XCTAssertFalse(hubs.isEmpty)
    }
}

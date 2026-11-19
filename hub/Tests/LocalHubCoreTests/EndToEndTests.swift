import CryptoKit
import Foundation
import Vapor
import XCTest
@testable import LocalHubCore

/// Real TLS hub + a fake LM Studio on loopback, driven by a client that trusts
/// nothing but the pinned fingerprint — the same contract the SDKs implement.
final class EndToEndTests: XCTestCase, @unchecked Sendable {
    private var fakeLMStudio: Application!
    private var server: HubServer!
    private var directory: URL!
    private var core: HubCore!
    private var hubURL: URL!

    override func setUp() async throws {
        directory = try temporaryDirectory()
        fakeLMStudio = try await Application.make(.testing)
        fakeLMStudio.get("v1", "models") { _ in
            Response(status: .ok, headers: ["Content-Type": "application/json"],
                body: .init(string: #"{"object":"list","data":[{"id":"qwen/qwen3-8b","object":"model"},{"id":"nomic-embed","object":"model"}]}"#))
        }
        fakeLMStudio.get("api", "v1", "models") { _ in
            Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: #"""
            {"models": [{"key": "qwen/qwen3-8b", "display_name": "Qwen3 8B", "type": "llm", "size_bytes": 5000000000,
                         "loaded_instances": [{"id": "qwen/qwen3-8b", "config": {}}]},
                        {"key": "nomic-embed", "type": "embedding", "size_bytes": 84000000, "loaded_instances": []}]}
            """#))
        }
        fakeLMStudio.post("api", "v1", "models", "load") { request async throws -> Response in
            let body = try JSONSerialization.jsonObject(with: Data(request.body.data!.readableBytesView)) as! [String: Any]
            return Response(status: .ok, body: .init(string: #"{"type": "llm", "instance_id": "\#(body["model"] as! String)", "status": "loaded"}"#))
        }
        fakeLMStudio.post("api", "v1", "models", "unload") { request async throws -> Response in
            let body = try JSONSerialization.jsonObject(with: Data(request.body.data!.readableBytesView)) as! [String: Any]
            return Response(status: .ok, body: .init(string: #"{"instance_id": "\#(body["instance_id"] as! String)"}"#))
        }
        fakeLMStudio.post("v1", "embeddings") { request async throws -> Response in
            let body = try JSONSerialization.jsonObject(with: Data(request.body.data!.readableBytesView)) as! [String: Any]
            return Response(status: .ok, headers: ["Content-Type": "application/json"],
                body: .init(string: #"{"object": "list", "model": "\#(body["model"] as! String)", "data": [{"object": "embedding", "index": 0, "embedding": [0.1, 0.2]}]}"#))
        }
        fakeLMStudio.post("v1", "chat", "completions") { request async throws -> Response in
            let body = try JSONSerialization.jsonObject(with: Data(request.body.data!.readableBytesView)) as! [String: Any]
            let model = body["model"] as! String
            if body["stream"] as? Bool == true {
                return Response(status: .ok, headers: ["Content-Type": "text/event-stream"],
                    body: .init(string: "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Greeting asked.\"}}]}\n\n"
                        + "data: {\"model\":\"\(model)\",\"choices\":[{\"delta\":{\"content\":\"Mer\"}}]}\n\n"
                        + "data: {\"choices\":[{\"delta\":{\"content\":\"haba\"}}]}\n\ndata: [DONE]\n\n"))
            }
            return Response(status: .ok, headers: ["Content-Type": "application/json"],
                body: .init(string: #"{"model":"\#(model)","choices":[{"message":{"role":"assistant","content":"Merhaba"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}"#))
        }
        try await fakeLMStudio.server.start(address: .hostname("127.0.0.1", port: 0))
        let upstreamPort = try XCTUnwrap(fakeLMStudio.http.server.shared.localAddress?.port)

        core = try HubCore(directory: directory)
        try core.integrations.save(ProviderConfiguration(id: "lmstudio", kind: .openai, name: "LM Studio",
            baseURL: "http://127.0.0.1:\(upstreamPort)"))
        // Port 1 is never listening: apps that are not running.
        try core.integrations.save(ProviderConfiguration(id: "ollama", kind: .openai, name: "Ollama", baseURL: "http://127.0.0.1:1"))
        try core.integrations.save(ProviderConfiguration(id: "comfyui", kind: .comfyui, name: "ComfyUI", baseURL: "http://127.0.0.1:1"))
        server = HubServer(core: core)
        try await server.start(settings: HubSettings(), portOverride: 0)
        let boundPort = await server.port; let port = try XCTUnwrap(boundPort)
        hubURL = URL(string: "https://127.0.0.1:\(port)")!
    }

    override func tearDown() async throws {
        await server.stop()
        await fakeLMStudio.server.shutdown(); try await fakeLMStudio.asyncShutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func testPairAndListModelsOverPinnedTLS() async throws {
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let token = try await pair(client)

        let (models, status) = try await client.json("GET", hubURL.appendingPathComponent("v1/models"), token: token)
        XCTAssertEqual(status, 200)
        let ids = (models["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["lmstudio/qwen/qwen3-8b", "lmstudio/nomic-embed"], "stopped Ollama is skipped, not fatal")
        let entries = models["data"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.first?["loaded"] as? Bool, true, "LM Studio reports what is in memory")
        XCTAssertEqual(entries.last?["capabilities"] as? [String], ["embeddings"], "embedding models are marked as such")

        let (chat, _) = try await client.json("POST", hubURL.appendingPathComponent("v1/chat/completions"), token: token,
            body: ["model": "lmstudio/qwen/qwen3-8b", "messages": [["role": "user", "content": "hi"]]])
        XCTAssertEqual(chat["model"] as? String, "qwen/qwen3-8b", "provider prefix is stripped upstream")

        let (stream, streamStatus) = try await client.raw("POST", hubURL.appendingPathComponent("v1/chat/completions"),
            token: token, body: ["model": "lmstudio/qwen/qwen3-8b", "stream": true, "messages": []])
        XCTAssertEqual(streamStatus, 200)
        XCTAssertTrue(String(decoding: stream, as: UTF8.self).hasSuffix("data: [DONE]\n\n"))

        let (providers, _) = try await client.rawJSONArray("GET", hubURL.appendingPathComponent("v2/integrations"), token: token)
        XCTAssertEqual(providers.map { "\($0["id"]!)=\($0["state"]!)" }, ["lmstudio=running", "ollama=unreachable", "comfyui=unreachable"])
    }

    func testStoppedProviderAnswersWithAMeaningfulError() async throws {
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let token = try await pair(client)
        let (body, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/chat/completions"),
            token: token, body: ["model": "ollama/llama3", "messages": []])
        XCTAssertEqual(status, 503)
        let error = try XCTUnwrap(body["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "provider_unavailable")
        XCTAssertEqual(error["provider"] as? String, "ollama")
        XCTAssertEqual(error["message"] as? String, "Ollama is not running on this Mac (http://127.0.0.1:1)")
    }

    func testScopesAndAuthenticationAreEnforced() async throws {
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let (_, anonymous) = try await client.json("GET", hubURL.appendingPathComponent("v1/models"), token: nil)
        XCTAssertEqual(anonymous, 401)

        let imageOnly = try await pair(client, scopes: ["image.edit"])
        let (body, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/chat/completions"),
            token: imageOnly, body: ["model": "lmstudio/qwen/qwen3-8b", "messages": []])
        XCTAssertEqual(status, 403)
        XCTAssertEqual((body["error"] as? [String: Any])?["code"] as? String, "forbidden")
    }

    func testWrongPinNeverReachesTheHub() async throws {
        let client = PinnedClient(fingerprint: String(repeating: "0", count: 64))
        do {
            _ = try await client.json("GET", hubURL.appendingPathComponent("v2/hub"), token: nil)
            XCTFail("Connected with the wrong pin")
        } catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
    }

    func testLegacyV1RoutesServeCompanionClients() async throws {
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let window = await core.authority.openWindow()
        let (paired, _) = try await client.json("POST", hubURL.appendingPathComponent("pair"), token: nil,
            body: ["code": window.code, "deviceName": "MatePad"])
        let token = try XCTUnwrap(paired["token"] as? String)
        let (models, status) = try await client.json("GET", hubURL.appendingPathComponent("lm/v1/models"), token: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual((models["data"] as? [[String: Any]])?.first?["id"] as? String, "qwen/qwen3-8b", "v1 keeps raw ids")
    }

    func testIntegrationEditsApplyWithoutRestartAndServerRestarts() async throws {
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let token = try await pair(client)
        try core.integrations.delete("ollama")
        let (models, status) = try await client.json("GET", hubURL.appendingPathComponent("v1/models"), token: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual((models["data"] as? [[String: Any]])?.count, 2, "LM Studio's two models; Ollama's are gone")
        let (body, missing) = try await client.json("POST", hubURL.appendingPathComponent("v1/chat/completions"),
            token: token, body: ["model": "ollama/llama3", "messages": []])
        XCTAssertEqual(missing, 404, "removed integration no longer routes: \(body)")

        var settings = HubSettings()
        settings.legacyV1 = false
        await server.stop()
        let stopped = await server.isRunning
        XCTAssertFalse(stopped)
        try await server.start(settings: settings, portOverride: 0)
        let boundPort = await server.port; let port = try XCTUnwrap(boundPort)
        let restarted = URL(string: "https://127.0.0.1:\(port)")!
        let (_, legacy) = try await client.json("GET", restarted.appendingPathComponent("lm/v1/models"), token: token)
        XCTAssertEqual(legacy, 404, "v1 routes are off after restart")
        let (_, v2) = try await client.json("GET", restarted.appendingPathComponent("v1/models"), token: token)
        XCTAssertEqual(v2, 200, "token survives the restart")
    }

    func testChatsAreLoggedWithStreamsErrorsAndRedactedImages() async throws {
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let token = try await pair(client)
        let url = hubURL.appendingPathComponent("v1/chat/completions")
        let image = "data:image/png;base64," + String(repeating: "A", count: 5000)
        _ = try await client.json("POST", url, token: token, body: ["model": "lmstudio/qwen/qwen3-8b", "messages": [
            ["role": "system", "content": "Be brief"],
            ["role": "user", "content": [["type": "text", "text": "describe this lighthouse"], ["type": "image_url", "image_url": ["url": image]]]],
        ]])
        _ = try await client.raw("POST", url, token: token, body: ["model": "lmstudio/qwen/qwen3-8b", "stream": true,
            "messages": [["role": "user", "content": "say hello in Turkish"]]])
        _ = try await client.json("POST", url, token: token, body: ["model": "ollama/llama3", "messages": [["role": "user", "content": "hi"]]])
        try await Task.sleep(for: .milliseconds(200))

        let logs = try core.store.chatLogs()
        XCTAssertEqual(logs.count, 3)
        let stream = try XCTUnwrap(logs.first { $0.stream })
        XCTAssertEqual(stream.response, "Merhaba")
        XCTAssertEqual(stream.reasoning, "Greeting asked.", "thinking is kept apart from the reply")
        XCTAssertEqual(stream.status, "completed")
        let plain = try XCTUnwrap(logs.first { $0.prompt.contains("lighthouse") })
        XCTAssertEqual(plain.response, "Merhaba")
        XCTAssertEqual(plain.finishReason, "stop")
        XCTAssertEqual(plain.promptTokens, 5)
        XCTAssertEqual(plain.completionTokens, 2)
        XCTAssertEqual(plain.model, "lmstudio/qwen/qwen3-8b")
        XCTAssertFalse(plain.messages.contains("base64"), "inline images are not stored")
        XCTAssertEqual(plain.decodedMessages.map(\.role), ["system", "user"])
        XCTAssertEqual(plain.decodedMessages.last?.text, "describe this lighthouse\n[image]")
        let failed = try XCTUnwrap(logs.first { $0.integrationID == "ollama" })
        XCTAssertEqual(failed.status, "error")
        XCTAssertEqual(failed.error, "Ollama is not running on this Mac (http://127.0.0.1:1)")

        XCTAssertEqual(try core.store.chatLogs(search: "lighth").map(\.id), [plain.id], "prefix search over prompts")
        XCTAssertEqual(try core.store.chatLogs(search: "merhaba").count, 2, "and responses")
        XCTAssertEqual(try core.store.chatLogs(search: "zebra").count, 0)
    }

    func testLoggingCanBeTurnedOffAndLogsExpireOrLeaveWithTheDevice() async throws {
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let token = try await pair(client)
        let url = hubURL.appendingPathComponent("v1/chat/completions")
        let body: [String: Any] = ["model": "lmstudio/qwen/qwen3-8b", "messages": [["role": "user", "content": "hi"]]]
        _ = try await client.json("POST", url, token: token, body: body)
        let devices = await core.authority.listDevices(); let device = try XCTUnwrap(devices.last)
        try await core.authority.update(device.id) { $0.logging = false }
        _ = try await client.json("POST", url, token: token, body: body)
        XCTAssertEqual(try core.store.chatLogs(deviceID: device.id).count, 1, "nothing recorded while logging is off")
        XCTAssertEqual(try core.store.usage(since: .distantPast).totalRequests, 2, "Usage is independent of content logging")

        XCTAssertEqual(core.purgeExpiredChatLogs(now: Date().addingTimeInterval(29 * 86_400)), 0)
        XCTAssertEqual(core.purgeExpiredChatLogs(now: Date().addingTimeInterval(31 * 86_400)), 1, "30-day default retention")
        XCTAssertEqual(try core.store.usage(since: .distantPast).totalRequests, 2)

        try await core.authority.update(device.id) { $0.logging = true }
        _ = try await client.json("POST", url, token: token, body: body)
        try await core.authority.revoke(device.id)
        XCTAssertEqual(try core.store.chatLogs(deviceID: device.id).count, 0, "removing a device removes its logs")
        XCTAssertEqual(try core.store.usage(since: .distantPast).totalRequests, 3)
    }

    func testEmbeddingsAndLMStudioModelManagement() async throws {
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        let token = try await pair(client)
        let (embedding, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/embeddings"), token: token,
            body: ["model": "lmstudio/nomic-embed", "input": "a fox"])
        XCTAssertEqual(status, 200, "\(embedding)")
        XCTAssertEqual(embedding["model"] as? String, "nomic-embed", "provider prefix is stripped upstream")
        XCTAssertEqual(try core.store.usage(since: .distantPast).days.first?.capability, "embeddings")
        XCTAssertTrue(try core.store.chatLogs().isEmpty)

        let manager = LMStudioManager(integration: try XCTUnwrap(core.integrations.list.first { $0.id == "lmstudio" }))
        let catalog = try await manager.catalog()
        XCTAssertEqual(catalog.map(\.key), ["qwen/qwen3-8b", "nomic-embed"])
        XCTAssertEqual(catalog.first?.loaded, true)
        XCTAssertEqual(catalog.last?.type, "embedding")
        try await manager.load("nomic-embed")
        try await manager.unload(instance: "qwen/qwen3-8b")
        let ollama = LMStudioManager(integration: try XCTUnwrap(core.integrations.list.first { $0.id == "ollama" }))
        do { _ = try await ollama.catalog(); XCTFail("Ollama has no LM Studio API") } catch {}
    }

    func testRejectedAndExecutedRequestsHaveOneMetadataRecordEachWithoutChatLogging() async throws {
        let client = PinnedClient(fingerprint: core.certificate.fingerprint), token = try await pair(client)
        let devices = await core.authority.listDevices(), device = try XCTUnwrap(devices.last)
        try await core.authority.update(device.id) { $0.logging = false }
        let url = hubURL.appendingPathComponent("v1/chat/completions")
        let messages = [["role": "user", "content": "do-not-retain-this-prompt"]]
        let invalid = try await client.json("POST", url, token: token, body: ["messages": messages])
        XCTAssertEqual(invalid.1, 400)
        let missing = try await client.json("POST", url, token: token, body: ["model": "unknown/model", "messages": messages])
        XCTAssertEqual(missing.1, 404)
        _ = try await client.json("POST", url, token: token, body: ["model": "lmstudio/qwen/qwen3-8b", "messages": messages])
        let report = try core.store.usage(since: .distantPast)
        XCTAssertEqual(report.totalRequests, 3)
        XCTAssertEqual(report.models.reduce(0) { $0 + $1.failures }, 2)
        XCTAssertTrue(try core.store.chatLogs().isEmpty)
    }

    private func pair(_ client: PinnedClient, scopes: [String]? = nil) async throws -> String {
        let window = await core.authority.openWindow()
        var body: [String: Any] = ["code": window.code, "deviceName": "Test device", "app": "tests"]
        if let scopes { body["scopes"] = scopes }
        let (result, status) = try await client.json("POST", hubURL.appendingPathComponent("v2/pair"), token: nil, body: body)
        XCTAssertEqual(status, 200)
        return try XCTUnwrap(result["token"] as? String)
    }
}

/// Minimal pinned client: no CA, no hostname check, only the SHA-256 of the leaf.
final class PinnedClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    let fingerprint: String
    private(set) lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let der = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return actual == fingerprint ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    func raw(_ method: String, _ url: URL, token: String?, body: [String: Any]? = nil,
             headers: [String: String] = [:]) async throws -> (Data, Int) {
        try await sendRaw(method, url, token: token, body: try body.map { try JSONSerialization.data(withJSONObject: $0) },
            contentType: body == nil ? nil : "application/json", headers: headers)
    }

    func sendRaw(_ method: String, _ url: URL, token: String?, body: Data?, contentType: String?,
                 headers: [String: String] = [:]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    func send(_ method: String, _ url: URL, token: String?, body: Data, contentType: String) async throws -> ([String: Any], Int) {
        let (data, status) = try await sendRaw(method, url, token: token, body: body, contentType: contentType)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], status)
    }

    func json(_ method: String, _ url: URL, token: String?, body: [String: Any]? = nil,
              headers: [String: String] = [:]) async throws -> ([String: Any], Int) {
        let (data, status) = try await raw(method, url, token: token, body: body, headers: headers)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], status)
    }

    func rawJSONArray(_ method: String, _ url: URL, token: String?) async throws -> ([[String: Any]], Int) {
        let (data, status) = try await raw(method, url, token: token)
        return ((try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? [], status)
    }
}

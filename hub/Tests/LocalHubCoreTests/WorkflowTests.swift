import Foundation
import Vapor
import XCTest
@testable import LocalHubCore

let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../examples/workflows").standardized

func sample(_ name: String) throws -> String {
    try String(contentsOf: samples.appendingPathComponent(name), encoding: .utf8)
}

/// 1×1 transparent PNG.
let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

let fakeWebM = Data([0x1A, 0x45, 0xDF, 0xA3]) + Data("webm".utf8)
let fakeFLAC = Data("fLaC-audio".utf8)

/// Stable Audio Open–style text to audio (API format).
let audioWorkflow = #"""
{
  "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "stable_audio_open_1.0.safetensors"}},
  "10": {"class_type": "CLIPLoader", "inputs": {"clip_name": "t5_base.safetensors", "type": "stable_audio"}},
  "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "rain on a tin roof", "clip": ["10", 0]}},
  "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["10", 0]}},
  "11": {"class_type": "EmptyLatentAudio", "inputs": {"seconds": 47.6, "batch_size": 1}},
  "3": {"class_type": "KSampler", "inputs": {"seed": 1, "steps": 50, "cfg": 5, "sampler_name": "dpmpp_3m_sde_gpu", "scheduler": "exponential", "denoise": 1, "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["11", 0]}},
  "12": {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
  "9": {"class_type": "SaveAudio", "inputs": {"filename_prefix": "audio/localhub", "audio": ["12", 0]}}
}
"""#

final class WorkflowGraphTests: XCTestCase {
    func testDetectsVideoAndAudioWorkflows() throws {
        let video = try WorkflowGraph(json: sample("wan22-5b-text-to-video.json")).detectSlots()
        XCTAssertEqual(video.capability, .videoCreate)
        XCTAssertEqual(video.outputNode, "60")
        XCTAssertTrue(Set(video.slots).isSuperset(of: [
            .init(kind: .prompt, node: "6", input: "text"), .init(kind: .frames, node: "55", input: "length"),
            .init(kind: .fps, node: "60", input: "fps"), .init(kind: .width, node: "55", input: "width"),
        ]), "\(video.slots)")

        let audio = try WorkflowGraph(json: audioWorkflow).detectSlots()
        XCTAssertEqual(audio.capability, .audioCreate)
        XCTAssertEqual(audio.outputNode, "9")
        XCTAssertTrue(audio.slots.contains(.init(kind: .seconds, node: "11", input: "seconds")))

        let tts = try WorkflowGraph(json: #"{"1": {"class_type": "KokoroTTS", "inputs": {"text": "hi", "voice": "af"}}, "2": {"class_type": "SaveAudio", "inputs": {"filename_prefix": "x", "audio": ["1", 0]}}}"#).detectSlots()
        XCTAssertEqual(tts.slots, [.init(kind: .prompt, node: "1", input: "text")], "TTS nodes get their text input as the prompt")
    }

    func testDetectsSlotsInShippedSamples() throws {
        let create = try WorkflowGraph(json: sample("sdxl-text-to-image.json")).detectSlots()
        XCTAssertEqual(create.capability, .imageCreate)
        XCTAssertEqual(create.outputNode, "9")
        XCTAssertEqual(Set(create.slots), [
            .init(kind: .prompt, node: "6", input: "text"), .init(kind: .negativePrompt, node: "7", input: "text"),
            .init(kind: .seed, node: "3", input: "seed"), .init(kind: .steps, node: "3", input: "steps"),
            .init(kind: .denoise, node: "3", input: "denoise"),
            .init(kind: .width, node: "5", input: "width"), .init(kind: .height, node: "5", input: "height"),
        ])
        let edit = try WorkflowGraph(json: sample("sdxl-inpaint.json")).detectSlots()
        XCTAssertEqual(edit.capability, .imageEdit)
        XCTAssertTrue(edit.slots.contains(.init(kind: .image, node: "10", input: "image")))
        XCTAssertTrue(edit.slots.contains(.init(kind: .mask, node: "11", input: "image")))
    }

    func testRejectsUIFormatAndBadSlots() throws {
        XCTAssertThrowsError(try WorkflowGraph(json: #"{"nodes": [], "links": []}"#)) { error in
            XCTAssertTrue("\(error)".contains("Export (API)"))
        }
        var template = WorkflowTemplate(id: "t", name: "T", integrationID: "comfyui", capability: .imageCreate,
            workflow: try sample("sdxl-text-to-image.json"), slots: [.init(kind: .prompt, node: "6", input: "clip")], outputNode: "9")
        XCTAssertThrowsError(try template.validate(), "clip is a link, not a literal input")
        template.slots = [.init(kind: .prompt, node: "6", input: "text")]
        XCTAssertNoThrow(try template.validate())
        template.capability = .imageEdit
        XCTAssertThrowsError(try template.validate(), "edit needs an image slot")
    }
}

/// Just enough ComfyUI: upload, prompt, history, view, queue, interrupt.
final class FakeComfy: @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [[String: Any]] = []
    private var _uploads: [String] = []
    private var _interrupted: [String] = []
    private var _promptIDs: [String] = []
    var slow = false
    /// Prompts ComfyUI reports ahead of ours (one running, the rest pending).
    var ahead = 0
    var ramFreeGB: Double?
    /// Replaces the history `outputs` body, e.g. a 3D mesh.
    var outputOverride: String?
    /// When set, history reports the prompt as failed with this `exception_message`.
    var executionError: String?
    /// `devices[0].type` in `/system_stats`, e.g. `mps`.
    var device: String?
    private var sockets: [String: WebSocket] = [:]

    /// Pushes a WebSocket event to the hub as ComfyUI would.
    func send(_ clientID: String, text: String) { lock.withLock { sockets[clientID] }?.send(text) }
    func send(_ clientID: String, binary: Data) { lock.withLock { sockets[clientID] }?.send([UInt8](binary)) }
    var prompts: [[String: Any]] { lock.withLock { _prompts } }
    var uploads: [String] { lock.withLock { _uploads } }
    var interrupted: [String] { lock.withLock { _interrupted } }
    var promptIDs: [String] { lock.withLock { _promptIDs } }

    func routes(_ app: Application) {
        app.on(.POST, "upload", "image", body: .collect(maxSize: "10mb")) { request in
            struct Form: Content { var image: File }
            let form = try request.content.decode(Form.self)
            self.lock.withLock { self._uploads.append(form.image.filename) }
            return ["name": form.image.filename, "subfolder": "", "type": "input"]
        }
        app.post("prompt") { request -> [String: String] in
            let body = try JSONSerialization.jsonObject(with: Data(request.body.data!.readableBytesView)) as! [String: Any]
            let id = UUID().uuidString.lowercased()
            self.lock.withLock { self._prompts.append(body["prompt"] as! [String: Any]); self._promptIDs.append(id) }
            return ["prompt_id": id]
        }
        app.get("history", ":id") { request -> Response in
            let id = request.parameters.get("id")!
            if self.slow { return Response(status: .ok, body: .init(string: "{}")) }
            if let message = self.executionError {
                let detail = try JSONSerialization.data(withJSONObject: ["node_id": "3", "node_type": "KSampler", "exception_message": message])
                let json = #"{"\#(id)": {"status": {"status_str": "error", "completed": false, "messages": [["execution_start", {}], ["execution_error", \#(String(decoding: detail, as: UTF8.self))]]}, "outputs": {}}}"#
                return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: json))
            }
            let graph = self.lock.withLock { self._promptIDs.firstIndex(of: id).map { self._prompts[$0] } } ?? [:]
            let classes = graph.values.compactMap { ($0 as? [String: Any])?["class_type"] as? String }
            let output = self.outputOverride ?? (classes.contains("SaveWEBM") ? #""60": {"images": [{"filename": "out.webm", "subfolder": "", "type": "output"}], "animated": [true]}"#
                : classes.contains("SaveAudio") ? #""9": {"audio": [{"filename": "out.flac", "subfolder": "audio", "type": "output"}]}"#
                : #""9": {"images": [{"filename": "out.png", "subfolder": "", "type": "output"}]}"#)
            let json = #"{"\#(id)": {"status": {"status_str": "success", "completed": true}, "outputs": {\#(output)}}}"#
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: json))
        }
        app.get("view") { request -> Response in
            let name = try request.query.get(String.self, at: "filename")
            let (data, type) = name.hasSuffix(".webm") ? (fakeWebM, "video/webm") : name.hasSuffix(".flac") ? (fakeFLAC, "audio/flac")
                : name.hasSuffix(".glb") ? (Data("glTF".utf8), "application/octet-stream") : (tinyPNG, "image/png")
            return Response(status: .ok, headers: ["Content-Type": type], body: .init(data: data))
        }
        app.get("queue") { _ -> Response in
            let mine = self.promptIDs.last ?? ""
            if self.ahead > 0 {
                let others = (1..<self.ahead).map { #"[\#($0), "other-\#($0)"]"# }
                let pending = (others + [#"[99, "\#(mine)"]"#]).joined(separator: ", ")
                return Response(status: .ok, body: .init(string: #"{"queue_running": [[0, "busy"]], "queue_pending": [\#(pending)]}"#))
            }
            let running = mine.isEmpty ? "[]" : #"[[0, "\#(mine)"]]"#
            return Response(status: .ok, body: .init(string: #"{"queue_running": \#(running), "queue_pending": []}"#))
        }
        app.webSocket("ws") { request, socket in
            guard let id = request.query[String.self, at: "clientId"] else { return }
            self.lock.withLock { self.sockets[id] = socket }
        }
        app.post("interrupt") { request -> HTTPStatus in
            let body = try JSONSerialization.jsonObject(with: Data(request.body.data!.readableBytesView)) as? [String: Any]
            self.lock.withLock { self._interrupted.append(body?["prompt_id"] as? String ?? "") }
            return .ok
        }
        app.get("system_stats") { _ -> Response in
            let ram = self.ramFreeGB.map { #", "ram_free": \#(Int($0 * 1_073_741_824))"# } ?? ""
            let devices = self.device.map { #", "devices": [{"name": "\#($0)", "type": "\#($0)"}]"# } ?? ""
            return Response(status: .ok, body: .init(string: #"{"system": {"os": "fake"\#(ram)}\#(devices)}"#))
        }
    }
}

final class ImageJobTests: XCTestCase, @unchecked Sendable {
    private var comfy: Application!
    private var fake: FakeComfy!
    private var server: HubServer!
    private var core: HubCore!
    private var directory: URL!
    private var hubURL: URL!
    private var client: PinnedClient!

    override func setUp() async throws {
        directory = try temporaryDirectory()
        fake = FakeComfy()
        comfy = try await Application.make(.testing)
        fake.routes(comfy)
        try await comfy.server.start(address: .hostname("127.0.0.1", port: 0))
        let comfyPort = try XCTUnwrap(comfy.http.server.shared.localAddress?.port)

        core = try HubCore(directory: directory)
        try core.integrations.save(ProviderConfiguration(id: "comfyui", kind: .comfyui, name: "ComfyUI", baseURL: "http://127.0.0.1:\(comfyPort)"))
        for (id, file) in [("sdxl", "sdxl-text-to-image.json"), ("sdxl-inpaint", "sdxl-inpaint.json")] {
            let graph = try WorkflowGraph(json: sample(file)).detectSlots()
            try core.integrations.save(WorkflowTemplate(id: id, name: id, integrationID: "comfyui", capability: graph.capability,
                workflow: try sample(file), slots: graph.slots, outputNode: graph.outputNode))
        }
        server = HubServer(core: core)
        try await server.start(settings: HubSettings(), portOverride: 0)
        let boundPort = await server.port
        hubURL = URL(string: "https://127.0.0.1:\(try XCTUnwrap(boundPort))")!
        client = PinnedClient(fingerprint: core.certificate.fingerprint)
    }

    override func tearDown() async throws {
        await server.stop()
        await comfy.server.shutdown(); try await comfy.asyncShutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func pair(scopes: [String]? = nil) async throws -> String {
        let window = await core.authority.openWindow()
        var body: [String: Any] = ["code": window.code, "deviceName": "Tablet", "app": "tests"]
        if let scopes { body["scopes"] = scopes }
        let (result, _) = try await client.json("POST", hubURL.appendingPathComponent("v2/pair"), token: nil, body: body)
        return try XCTUnwrap(result["token"] as? String)
    }

    func testGenerateFillsTheTemplateAndStoresTheOutputAsAFile() async throws {
        let token = try await pair()
        let (models, _) = try await client.json("GET", hubURL.appendingPathComponent("v1/models"), token: token)
        let ids = (models["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertTrue(ids.contains("comfyui/sdxl") && ids.contains("comfyui/sdxl-inpaint"), "\(ids)")

        let (body, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/images/generations"), token: token,
            body: ["prompt": "a paper boat", "size": "512x768", "seed": 7, "negative_prompt": "rain"])
        XCTAssertEqual(status, 200, "\(body)")
        let item = try XCTUnwrap((body["data"] as? [[String: Any]])?.first)
        XCTAssertEqual(Data(base64Encoded: item["b64_json"] as? String ?? ""), tinyPNG)
        let fileID = try XCTUnwrap(item["file_id"] as? String)

        let graph = try XCTUnwrap(fake.prompts.last)
        func input(_ node: String, _ key: String) -> Any? { ((graph[node] as? [String: Any])?["inputs"] as? [String: Any])?[key] }
        XCTAssertEqual(input("6", "text") as? String, "a paper boat")
        XCTAssertEqual(input("7", "text") as? String, "rain")
        XCTAssertEqual(input("3", "seed") as? Int, 7)
        XCTAssertEqual(input("5", "width") as? Int, 512)
        XCTAssertEqual(input("5", "height") as? Int, 768)

        let (files, _) = try await client.json("GET", hubURL.appendingPathComponent("v1/files"), token: token)
        XCTAssertEqual((files["data"] as? [[String: Any]])?.first?["id"] as? String, fileID)
        let (content, contentStatus) = try await client.raw("GET", hubURL.appendingPathComponent("v1/files/\(fileID)/content"), token: token)
        XCTAssertEqual(contentStatus, 200)
        XCTAssertEqual(content, tinyPNG)

        let other = try await pair()
        let (_, hidden) = try await client.raw("GET", hubURL.appendingPathComponent("v1/files/\(fileID)/content"), token: other)
        XCTAssertEqual(hidden, 404, "files belong to the device that made them")
    }

    func testEditUploadsImageAndUsesItsAlphaAsMask() async throws {
        let token = try await pair()
        let (body, status) = try await client.multipart(hubURL.appendingPathComponent("v1/images/edits"), token: token,
            fields: ["prompt": "add a hat", "response_format": "url"], files: [("image", "photo.png", tinyPNG)])
        XCTAssertEqual(status, 200, "\(body)")
        let item = try XCTUnwrap((body["data"] as? [[String: Any]])?.first)
        XCTAssertTrue((item["url"] as? String)?.hasSuffix("/v1/files/\(item["file_id"] as? String ?? "")/content") == true)
        XCTAssertNil(item["b64_json"])
        XCTAssertEqual(fake.uploads.count, 2, "image and mask (from the image's alpha) are uploaded")
        let graph = try XCTUnwrap(fake.prompts.last)
        let loadImage = ((graph["10"] as? [String: Any])?["inputs"] as? [String: Any])?["image"] as? String
        XCTAssertTrue(loadImage?.hasPrefix("localhub-job-") == true, "\(loadImage ?? "nil")")
    }

    func testAsyncJobCanBeCancelledAndOnlyByItsDevice() async throws {
        fake.slow = true
        let token = try await pair()
        let (job, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/images/generations"), token: token,
            body: ["prompt": "slow"], headers: ["Prefer": "respond-async"])
        XCTAssertEqual(status, 202)
        let id = try XCTUnwrap(job["id"] as? String)
        try await Task.sleep(for: .milliseconds(300))

        let other = try await pair()
        let (_, foreign) = try await client.json("POST", hubURL.appendingPathComponent("v1/jobs/\(id)/cancel"), token: other)
        XCTAssertEqual(foreign, 404)

        let (_, cancel) = try await client.json("POST", hubURL.appendingPathComponent("v1/jobs/\(id)/cancel"), token: token)
        XCTAssertEqual(cancel, 200)
        var state = ""
        for _ in 0..<30 where state != "cancelled" {
            try await Task.sleep(for: .milliseconds(100))
            state = (try await client.json("GET", hubURL.appendingPathComponent("v1/jobs/\(id)"), token: token)).0["status"] as? String ?? ""
        }
        XCTAssertEqual(state, "cancelled")
        XCTAssertEqual(fake.interrupted, fake.promptIDs, "only this job's prompt is interrupted")
    }

    func testCapabilityPermissionsAndMissingWorkflow() async throws {
        let chatOnly = try await pair(scopes: ["chat"])
        let (forbidden, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/images/generations"),
            token: chatOnly, body: ["prompt": "x"])
        XCTAssertEqual(status, 403, "\(forbidden)")

        try core.integrations.deleteTemplate("sdxl")
        let token = try await pair()
        let (missing, missingStatus) = try await client.json("POST", hubURL.appendingPathComponent("v1/images/generations"),
            token: token, body: ["prompt": "x"])
        XCTAssertEqual(missingStatus, 404)
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "capability_unavailable")

        try core.integrations.delete("comfyui")
        XCTAssertTrue(core.integrations.templates.isEmpty, "removing an integration removes its workflows")
    }

    func testFileUploadTypesQuotaAndDelete() async throws {
        var settings = HubSettings()
        settings.fileQuotaBytes = 100
        try core.store.save(settings)
        let token = try await pair()
        let (uploaded, status) = try await client.multipart(hubURL.appendingPathComponent("v1/files"), token: token,
            fields: ["purpose": "reference"], files: [("file", "ref.png", tinyPNG)])
        XCTAssertEqual(status, 200, "\(uploaded)")
        XCTAssertEqual(uploaded["purpose"] as? String, "reference")
        XCTAssertEqual(uploaded["mime_type"] as? String, "image/png")

        let (_, exe) = try await client.multipart(hubURL.appendingPathComponent("v1/files"), token: token,
            fields: [:], files: [("file", "tool.sh", Data("#!/bin/sh".utf8))])
        XCTAssertEqual(exe, 415)
        let (quota, quotaStatus) = try await client.multipart(hubURL.appendingPathComponent("v1/files"), token: token,
            fields: [:], files: [("file", "big.png", Data(count: 200))])
        XCTAssertEqual(quotaStatus, 413)
        XCTAssertEqual((quota["error"] as? [String: Any])?["code"] as? String, "quota_exceeded")

        let id = try XCTUnwrap(uploaded["id"] as? String)
        let (deleted, _) = try await client.json("DELETE", hubURL.appendingPathComponent("v1/files/\(id)"), token: token)
        XCTAssertEqual(deleted["deleted"] as? Bool, true)
        XCTAssertEqual(try core.files.list(deviceID: nil).count, 0)
    }
}

final class MediaJobTests: XCTestCase, @unchecked Sendable {
    private var comfy: Application!
    private var fake: FakeComfy!
    private var server: HubServer!
    private var core: HubCore!
    private var directory: URL!
    private var hubURL: URL!
    private var client: PinnedClient!

    override func setUp() async throws {
        directory = try temporaryDirectory()
        fake = FakeComfy()
        comfy = try await Application.make(.testing)
        fake.routes(comfy)
        try await comfy.server.start(address: .hostname("127.0.0.1", port: 0))
        core = try HubCore(directory: directory)
        try core.integrations.save(ProviderConfiguration(id: "comfyui", kind: .comfyui, name: "ComfyUI",
            baseURL: "http://127.0.0.1:\(try XCTUnwrap(comfy.http.server.shared.localAddress?.port))"))
        let video = try sample("wan22-5b-text-to-video.json")
        let videoSlots = try WorkflowGraph(json: video).detectSlots()
        try core.integrations.save(WorkflowTemplate(id: "wan", name: "Wan", integrationID: "comfyui", capability: .videoCreate,
            workflow: video, slots: videoSlots.slots, outputNode: videoSlots.outputNode))
        let audioSlots = try WorkflowGraph(json: audioWorkflow).detectSlots()
        for (id, capability) in [("stable-audio", Capability.audioCreate), ("voice", .audioSpeech)] {
            try core.integrations.save(WorkflowTemplate(id: id, name: id, integrationID: "comfyui", capability: capability,
                workflow: audioWorkflow, slots: audioSlots.slots, outputNode: audioSlots.outputNode))
        }
        server = HubServer(core: core)
        try await server.start(settings: HubSettings(), portOverride: 0)
        let port = await server.port
        hubURL = URL(string: "https://127.0.0.1:\(try XCTUnwrap(port))")!
        client = PinnedClient(fingerprint: core.certificate.fingerprint)
    }

    override func tearDown() async throws {
        await server.stop()
        await comfy.server.shutdown(); try await comfy.asyncShutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func pair() async throws -> String {
        let window = await core.authority.openWindow()
        let (result, _) = try await client.json("POST", hubURL.appendingPathComponent("v2/pair"), token: nil,
            body: ["code": window.code, "deviceName": "Olive", "app": "olive-studio"])
        return try XCTUnwrap(result["token"] as? String)
    }

    private func input(_ node: String, _ key: String) -> Any? {
        ((fake.prompts.last?[node] as? [String: Any])?["inputs"] as? [String: Any])?[key]
    }

    func testVideosFollowOpenAIsAsynchronousShape() async throws {
        let token = try await pair()
        let (created, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/videos"), token: token,
            body: ["prompt": "a paper boat", "seconds": "2", "size": "640x384"])
        XCTAssertEqual(status, 200, "\(created)")
        XCTAssertEqual(created["object"] as? String, "video")
        XCTAssertTrue(["queued", "in_progress"].contains(created["status"] as? String ?? ""))
        let id = try XCTUnwrap(created["id"] as? String)

        var video: [String: Any] = [:]
        for _ in 0..<40 where video["status"] as? String != "completed" {
            try await Task.sleep(for: .milliseconds(100))
            video = try await client.json("GET", hubURL.appendingPathComponent("v1/videos/\(id)"), token: token).0
        }
        XCTAssertEqual(video["status"] as? String, "completed")
        XCTAssertEqual(video["progress"] as? Int, 100)
        XCTAssertEqual(input("55", "length") as? Int, 49, "2 s × 24 fps, plus Wan's first frame")
        XCTAssertEqual(input("55", "width") as? Int, 640)

        let (content, contentStatus) = try await client.raw("GET", hubURL.appendingPathComponent("v1/videos/\(id)/content"), token: token)
        XCTAssertEqual(contentStatus, 200)
        XCTAssertEqual(content, fakeWebM)
        let file = try XCTUnwrap(try core.files.list(deviceID: nil).first)
        XCTAssertEqual(file.mime, "video/webm")

        let (remix, remixStatus) = try await client.json("POST", hubURL.appendingPathComponent("v1/videos/\(id)/remix"), token: token,
            body: ["prompt": "at night"])
        XCTAssertEqual(remixStatus, 404, "no edit workflow configured: \(remix)")

        let (deleted, _) = try await client.json("DELETE", hubURL.appendingPathComponent("v1/videos/\(id)"), token: token)
        XCTAssertEqual(deleted["deleted"] as? Bool, true)
        XCTAssertEqual(try core.files.list(deviceID: nil).count, 0, "deleting a video removes its file")
        let (_, gone) = try await client.json("GET", hubURL.appendingPathComponent("v1/videos/\(id)"), token: token)
        XCTAssertEqual(gone, 404)
    }

    func testAudioGenerationAndSpeech() async throws {
        let token = try await pair()
        let (generated, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/audio/generations"), token: token,
            body: ["prompt": "rain on a window", "seconds": 5])
        XCTAssertEqual(status, 200, "\(generated)")
        let item = try XCTUnwrap((generated["data"] as? [[String: Any]])?.first)
        XCTAssertEqual(Data(base64Encoded: item["b64_json"] as? String ?? ""), fakeFLAC)
        XCTAssertEqual(input("11", "seconds") as? Double, 5)

        var request = URLRequest(url: hubURL.appendingPathComponent("v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": "Merhaba", "voice": "alloy"])
        let (audio, response) = try await client.session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "audio/flac")
        XCTAssertEqual(audio, fakeFLAC)
        XCTAssertEqual(input("6", "text") as? String, "Merhaba", "speech input fills the prompt slot")
    }
}

extension PinnedClient {
    func multipart(_ url: URL, token: String, fields: [String: String], files: [(String, String, Data)]) async throws -> ([String: Any], Int) {
        let boundary = "test-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        for (name, filename, data) in files {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return try await send("POST", url, token: token, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}

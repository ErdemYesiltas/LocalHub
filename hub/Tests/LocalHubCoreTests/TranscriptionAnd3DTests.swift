import Foundation
import Vapor
import XCTest
@testable import LocalHubCore

/// whisper.cpp (`/inference`), an OpenAI-style transcription server, and a ComfyUI 3D workflow.
final class TranscriptionAnd3DTests: XCTestCase, @unchecked Sendable {
    private var whisperCpp: Application!
    private var openAIWhisper: Application!
    private var comfy: Application!
    private var server: HubServer!
    private var core: HubCore!
    private var directory: URL!
    private var hubURL: URL!
    private var client: PinnedClient!

    private func start(_ app: Application) async throws -> Int {
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        return try XCTUnwrap(app.http.server.shared.localAddress?.port)
    }

    override func setUp() async throws {
        directory = try temporaryDirectory()
        whisperCpp = try await Application.make(.testing)
        whisperCpp.on(.POST, "inference", body: .collect(maxSize: "10mb")) { request -> Response in
            struct Form: Content { var file: File; var language: String? }
            let form = try request.content.decode(Form.self)
            return Response(status: .ok, body: .init(string: #"{"text": " merhaba dünya (\#(form.file.filename), \#(form.language ?? "auto")) \n"}"#))
        }
        openAIWhisper = try await Application.make(.testing)
        openAIWhisper.on(.POST, "v1", "audio", "transcriptions", body: .collect(maxSize: "10mb")) { request -> Response in
            struct Form: Content { var file: File; var model: String; var response_format: String }
            let form = try request.content.decode(Form.self)
            return form.response_format == "text"
                ? Response(status: .ok, body: .init(string: "plain words from \(form.model)"))
                : Response(status: .ok, body: .init(string: #"{"text": "words from \#(form.model)"}"#))
        }
        comfy = try await Application.make(.testing)
        let fake = FakeComfy()
        fake.routes(comfy)

        core = try HubCore(directory: directory)
        try core.integrations.save(ProviderConfiguration(id: "whisper", kind: .whisper, name: "whisper.cpp",
            baseURL: "http://127.0.0.1:\(try await start(whisperCpp))"))
        try core.integrations.save(ProviderConfiguration(id: "speaches", kind: .whisper, name: "Speaches",
            baseURL: "http://127.0.0.1:\(try await start(openAIWhisper))"))
        try core.integrations.save(ProviderConfiguration(id: "comfyui", kind: .comfyui, name: "ComfyUI",
            baseURL: "http://127.0.0.1:\(try await start(comfy))"))
        let mesh = #"""
        {"1": {"class_type": "LoadImage", "inputs": {"image": "chair.png"}},
         "2": {"class_type": "ImageOnlyCheckpointLoader", "inputs": {"ckpt_name": "hunyuan3d.safetensors"}},
         "3": {"class_type": "KSampler", "inputs": {"seed": 1, "steps": 30, "cfg": 5, "sampler_name": "euler", "scheduler": "normal", "denoise": 1,
               "model": ["2", 0], "positive": ["1", 0], "negative": ["1", 0], "latent_image": ["1", 0]}},
         "9": {"class_type": "SaveGLB", "inputs": {"mesh": ["3", 0], "filename_prefix": "mesh/localhub"}}}
        """#
        let detected = try WorkflowGraph(json: mesh).detectSlots()
        XCTAssertEqual(detected.capability, .model3DCreate)
        try core.integrations.save(WorkflowTemplate(id: "hunyuan", name: "Hunyuan3D", integrationID: "comfyui",
            capability: detected.capability, workflow: mesh, slots: detected.slots, outputNode: detected.outputNode))
        fake.outputOverride = #""9": {"3d": [{"filename": "chair.glb", "subfolder": "mesh", "type": "output"}]}"#

        server = HubServer(core: core)
        var settings = HubSettings()
        settings.minFreeMemoryGB = 0
        try core.store.save(settings)
        try await server.start(settings: settings, portOverride: 0)
        let port = await server.port
        hubURL = URL(string: "https://127.0.0.1:\(try XCTUnwrap(port))")!
        client = PinnedClient(fingerprint: core.certificate.fingerprint)
    }

    override func tearDown() async throws {
        await server.stop()
        for app in [whisperCpp!, openAIWhisper!, comfy!] { await app.server.shutdown(); try await app.asyncShutdown() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func pair() async throws -> String {
        let window = await core.authority.openWindow()
        let (result, _) = try await client.json("POST", hubURL.appendingPathComponent("v2/pair"), token: nil,
            body: ["code": window.code, "deviceName": "Pad", "app": "tests"])
        return try XCTUnwrap(result["token"] as? String)
    }

    func testTranscriptionThroughWhisperCppAndOpenAIStyleServers() async throws {
        let token = try await pair()
        let url = hubURL.appendingPathComponent("v1/audio/transcriptions")
        let (native, status) = try await client.multipart(url, token: token, fields: ["language": "tr"], files: [("file", "note.wav", Data("RIFF".utf8))])
        XCTAssertEqual(status, 200, "\(native)")
        XCTAssertEqual(native["text"] as? String, "merhaba dünya (note.wav, tr)", "whisper.cpp's text, trimmed, in OpenAI's shape")

        let (openAI, _) = try await client.multipart(url, token: token, fields: ["model": "speaches/large-v3"], files: [("file", "a.wav", Data("RIFF".utf8))])
        XCTAssertEqual(openAI["text"] as? String, "words from large-v3", "falls back to /v1/audio/transcriptions with the upstream model")

        let boundary = "x"
        var body = Data("--x\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nspeaches/large-v3\r\n--x\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n".utf8)
        body.append(Data("--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n\r\nRIFF\r\n--x--\r\n".utf8))
        let (text, textStatus) = try await client.sendRaw("POST", url, token: token, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        XCTAssertEqual(textStatus, 200)
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "plain words from large-v3")
    }

    func testImageTo3DReturnsAGLBFile() async throws {
        let token = try await pair()
        let (result, status) = try await client.multipart(hubURL.appendingPathComponent("v1/3d/generations"), token: token,
            fields: [:], files: [("image", "chair.png", tinyPNG)])
        XCTAssertEqual(status, 200, "\(result)")
        let fileID = try XCTUnwrap((result["data"] as? [[String: Any]])?.first?["file_id"] as? String)
        let file = try core.files.get(fileID, deviceID: nil)
        XCTAssertEqual(file.mime, "model/gltf-binary")
        XCTAssertTrue(file.filename.hasSuffix(".glb"))
    }
}

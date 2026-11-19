import Foundation
import Vapor

public struct ProviderStatus: Content, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    /// `running`, `unreachable` or `error`.
    public let state: String
    public let capabilities: [String]
    public let models: Int?
    public let detail: String?
}

/// OpenAI model object with the hub's routing fields. `id` is
/// `<provider>/<upstream id>`, so one list can span several apps.
public struct HubModel: Content, Sendable, Equatable {
    public var id: String
    public var object = "model"
    public var owned_by: String
    public var provider: String
    public var upstream_id: String
    public var capabilities: [String]
    /// LM Studio only: whether the model is in memory (the first request to an unloaded one loads it).
    public var loaded: Bool?
}

struct OpenAIModelList: Codable, Sendable {
    struct Entry: Codable, Sendable { let id: String }
    let data: [Entry]
}

/// A Mac-local app speaking the OpenAI API: LM Studio, Ollama, llama.cpp
/// server, MLX server. Adding one is a config entry, not code.
struct OpenAICompatibleProvider: Sendable {
    let upstream: Upstream
    var id: String { upstream.provider.id }

    func models() async throws -> [HubModel] {
        async let catalog = LMStudioManager(upstream: upstream).models(timeout: 1.5)
        let list = try await upstream.getJSON("/v1/models", as: OpenAIModelList.self).data
        let details = Dictionary((try? await catalog) ?? [], uniquingKeysWith: { a, _ in a })
        return list.map { entry in
            let detail = details[entry.id]
            let embedding = detail.map { $0.type == "embedding" } ?? entry.id.lowercased().contains("embed")
            return HubModel(id: "\(id)/\(entry.id)", owned_by: id, provider: id, upstream_id: entry.id,
                capabilities: [embedding ? Capability.embeddings.rawValue : Capability.chat.rawValue],
                loaded: detail.map { !$0.instances.isEmpty })
        }
    }

    func status() async -> ProviderStatus {
        let config = upstream.provider
        do {
            let models = try await upstream.getJSON("/v1/models", as: OpenAIModelList.self, timeout: 1.5)
            return ProviderStatus(id: id, name: config.name, kind: config.kind.rawValue, state: "running",
                capabilities: ["chat", "models"], models: models.data.count, detail: nil)
        } catch let error as HubError {
            return ProviderStatus(id: id, name: config.name, kind: config.kind.rawValue,
                state: error.code == "provider_unavailable" ? "unreachable" : "error",
                capabilities: ["chat", "models"], models: nil, detail: error.message)
        } catch {
            return ProviderStatus(id: id, name: config.name, kind: config.kind.rawValue, state: "error",
                capabilities: ["chat", "models"], models: nil, detail: nil)
        }
    }
}

/// ComfyUI is exposed through a fixed set of its own routes: image jobs are
/// workflow graphs, not chat, so they get no OpenAI facade.
struct ComfyUIProvider: Sendable {
    let upstream: Upstream
    var id: String { upstream.provider.id }

    static let getPaths = ["system_stats", "object_info", "queue", "history", "view", "models/checkpoints"]
    static let postPaths = ["prompt", "upload/image", "upload/mask"]

    func status() async -> ProviderStatus {
        let config = upstream.provider
        struct Stats: Decodable {
            struct System: Decodable { let ram_free: Double?; let ram_total: Double? }
            let system: System?
        }
        do {
            let stats = try await upstream.getJSON("/system_stats", as: Stats.self, timeout: 1.5)
            let memory = stats.system?.ram_free.map { String(format: "%.1f GB free", $0 / 1_073_741_824) }
            return ProviderStatus(id: id, name: config.name, kind: config.kind.rawValue, state: "running",
                capabilities: ["image"], models: nil, detail: memory)
        } catch let error as HubError {
            return ProviderStatus(id: id, name: config.name, kind: config.kind.rawValue,
                state: error.code == "provider_unavailable" ? "unreachable" : "error",
                capabilities: ["image"], models: nil, detail: error.message)
        } catch {
            return ProviderStatus(id: id, name: config.name, kind: config.kind.rawValue, state: "error",
                capabilities: ["image"], models: nil, detail: nil)
        }
    }
}

public struct ProviderRegistry: Sendable {
    let chat: [OpenAICompatibleProvider]
    let image: [ComfyUIProvider]
    let whisper: [WhisperProvider]

    public init(_ configurations: [ProviderConfiguration]) {
        chat = configurations.filter { $0.kind == .openai }.map { OpenAICompatibleProvider(upstream: Upstream(provider: $0)) }
        image = configurations.filter { $0.kind == .comfyui }.map { ComfyUIProvider(upstream: Upstream(provider: $0)) }
        whisper = configurations.filter { $0.kind == .whisper }.map { WhisperProvider(upstream: Upstream(provider: $0)) }
    }

    func chatProvider(_ id: String) -> OpenAICompatibleProvider? { chat.first { $0.id == id } }
    func imageProvider(_ id: String) -> ComfyUIProvider? { image.first { $0.id == id } }

    public func statuses(include: (ProviderConfiguration) -> Bool = { _ in true }) async -> [ProviderStatus] {
        await withTaskGroup(of: (Int, ProviderStatus).self) { group in
            for (index, provider) in chat.enumerated() where include(provider.upstream.provider) {
                group.addTask { (index, await provider.status()) }
            }
            for (index, provider) in image.enumerated() where include(provider.upstream.provider) {
                group.addTask { (chat.count + index, await provider.status()) }
            }
            for (index, provider) in whisper.enumerated() where include(provider.upstream.provider) {
                group.addTask { (chat.count + image.count + index, await provider.status()) }
            }
            var result: [(Int, ProviderStatus)] = []
            for await entry in group { result.append(entry) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Models from every allowed, running chat provider. A stopped app is
    /// skipped, not an error, unless nothing at all answers.
    func chatModels() async throws -> [HubModel] {
        let providers = chat
        guard !providers.isEmpty else { return [] }
        let results = await withTaskGroup(of: (Int, Result<[HubModel], any Error>).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    do { return (index, .success(try await provider.models())) }
                    catch { return (index, .failure(error)) }
                }
            }
            var collected: [(Int, Result<[HubModel], any Error>)] = []
            for await entry in group { collected.append(entry) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let models = results.flatMap { (try? $0.get()) ?? [] }
        if models.isEmpty, results.allSatisfy({ if case .failure = $0 { true } else { false } }),
           case .failure(let first) = results[0] {
            if providers.count == 1 { throw first }
            throw HubError(.serviceUnavailable, "provider_unavailable",
                "No local model app is running (\(providers.map(\.upstream.provider.name).joined(separator: ", ")))")
        }
        return models
    }

    /// `lmstudio/qwen/qwen3-8b` → (lmstudio, `qwen/qwen3-8b`). An unprefixed id
    /// (Companion-era clients) is matched against the allowed providers' model lists.
    func route(model: String) async throws -> (OpenAICompatibleProvider, String) {
        if let slash = model.firstIndex(of: "/"), let provider = chatProvider(String(model[..<slash])) {
            return (provider, String(model[model.index(after: slash)...]))
        }
        // Never guess: an unknown id must not silently land on another app's model.
        for provider in chat {
            if let models = try? await provider.models(), models.contains(where: { $0.upstream_id == model }) {
                return (provider, model)
            }
        }
        throw HubError(.notFound, "model_not_found",
            "Unknown model \(model); use an id from /v1/models such as lmstudio/<model>")
    }
}

/// LM Studio's own REST API (`/api/v1/models`, `load`, `unload`). Other OpenAI-compatible apps don't
/// have it; every call here fails quietly for them.
public struct LMStudioManager: Sendable {
    let upstream: Upstream

    public init(integration: ProviderConfiguration) { upstream = Upstream(provider: integration) }
    init(upstream: Upstream) { self.upstream = upstream }

    public struct Model: Sendable, Identifiable, Equatable {
        public let key: String
        public let name: String
        /// `llm`, `vlm` or `embedding`.
        public let type: String
        public let sizeBytes: Int64
        public let instances: [String]
        public var id: String { key }
        public var loaded: Bool { !instances.isEmpty }
    }

    private struct Listing: Decodable {
        struct Entry: Decodable {
            struct Instance: Decodable { let id: String }
            let key: String
            let display_name: String?
            let type: String?
            let size_bytes: Int64?
            let loaded_instances: [Instance]?
        }
        let models: [Entry]
    }

    /// `nil` when the app is not LM Studio.
    public func catalog(timeout: TimeInterval = 5) async throws -> [Model] {
        try await upstream.getJSON("/api/v1/models", as: Listing.self, timeout: timeout).models.map {
            Model(key: $0.key, name: $0.display_name ?? $0.key, type: $0.type ?? "llm", sizeBytes: $0.size_bytes ?? 0,
                instances: ($0.loaded_instances ?? []).map(\.id))
        }
    }

    func models(timeout: TimeInterval) async throws -> [(String, Model)] {
        try await catalog(timeout: timeout).map { ($0.key, $0) }
    }

    public func load(_ key: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["model": key])
        let (data, response) = try await upstream.send("POST", "/api/v1/models/load", body: body, contentType: "application/json", timeout: 600)
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(data, upstream.provider.name) }
    }

    public func unload(instance: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["instance_id": instance])
        let (data, response) = try await upstream.send("POST", "/api/v1/models/unload", body: body, contentType: "application/json", timeout: 60)
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(data, upstream.provider.name) }
    }

    private static func failure(_ data: Data, _ name: String) -> HubError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String ?? json?["error"] as? String ?? "request failed"
        return HubError(.badGateway, "upstream_error", "\(name): \(message)")
    }
}

/// A transcription server on this Mac: whisper.cpp's `/inference`, or an OpenAI-style
/// `/v1/audio/transcriptions` (speaches, LocalAI, faster-whisper-server).
struct WhisperProvider: Sendable {
    let upstream: Upstream
    var id: String { upstream.provider.id }

    func status() async -> ProviderStatus {
        let config = upstream.provider
        do {
            _ = try await upstream.send("GET", "/", timeout: 1.5)
            return ProviderStatus(id: id, name: config.name, kind: config.kind.rawValue, state: "running",
                capabilities: ["transcribe"], models: nil, detail: nil)
        } catch let error as HubError {
            return ProviderStatus(id: id, name: config.name, kind: config.kind.rawValue,
                state: error.code == "provider_unavailable" ? "unreachable" : "error", capabilities: ["transcribe"], models: nil, detail: error.message)
        } catch {
            return ProviderStatus(id: id, name: config.name, kind: config.kind.rawValue, state: "error", capabilities: ["transcribe"], models: nil, detail: nil)
        }
    }

    /// Returns `(body, contentType)` in OpenAI's shape: `{"text": …}` for json, raw text for text/srt/vtt.
    func transcribe(audio: Data, filename: String, model: String?, language: String?, prompt: String?, format: String) async throws -> (Data, String) {
        func form(_ fields: [(String, String)]) -> (Data, String) {
            let boundary = "localhub-\(UUID().uuidString)"
            var body = Data()
            for (name, value) in fields {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(audio)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            return (body, "multipart/form-data; boundary=\(boundary)")
        }
        var fields: [(String, String)] = [("response_format", format)]
        if let language { fields.append(("language", language)) }
        if let prompt { fields.append(("prompt", prompt)) }
        let (native, nativeType) = form(fields)
        var (data, response) = try await upstream.send("POST", "/inference", body: native, contentType: nativeType, timeout: 600)
        if response.statusCode == 404 {
            let (openai, openaiType) = form(fields + [("model", model ?? "whisper-1")])
            (data, response) = try await upstream.send("POST", "/v1/audio/transcriptions", body: openai, contentType: openaiType, timeout: 600)
        }
        guard response.statusCode == 200 else {
            throw HubError(.badGateway, "upstream_error", "\(upstream.provider.name) could not transcribe the audio (HTTP \(response.statusCode))", provider: id)
        }
        if format == "json" || format == "verbose_json" {
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw HubError(.badGateway, "upstream_error", "\(upstream.provider.name) sent an unexpected transcription", provider: id)
            }
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized: [String: Any] = format == "json" ? ["text": text] : json.merging(["text": text]) { _, new in new }
            return (try JSONSerialization.data(withJSONObject: normalized), "application/json")
        }
        return (data, "text/plain; charset=utf-8")
    }
}

import Foundation
import Vapor

/// ArtBlend Companion v1 surface, kept so ArtBlend builds that only know the
/// `artblend-companion://` QR keep working during the move to protocol v2.
/// Upstream ids are passed through raw (no `lmstudio/` prefix).
func registerLegacyV1(_ app: Application, _ protected: any RoutesBuilder, core: HubCore, mcp: MCPRegistry) {
    struct LegacyDevice: Content { let id: String; let name: String; let createdAt: Date }
    let integrations = core.integrations

    app.get("health") { _ in ["status": "ok", "service": "localhub", "version": hubVersion] }
    app.post("pair") { request async throws -> PairingResult in
        let input = try request.content.decode(PairRequest.self)
        return try await pair(core, input, app: input.app ?? "artblend")
    }

    protected.get("devices") { request async throws -> [LegacyDevice] in
        let device = try request.device
        return [LegacyDevice(id: device.id, name: device.name, createdAt: device.createdAt)]
    }
    protected.delete("devices", ":id") { request async throws -> HTTPStatus in
        let device = try request.device
        guard request.parameters.get("id") == device.id else {
            throw HubError(.forbidden, "forbidden", "Devices can only be revoked from the Mac or by themselves")
        }
        try await core.authority.revoke(device.id)
        return .noContent
    }

    @Sendable func lmStudio(_ request: Request) async throws -> OpenAICompatibleProvider {
        guard let provider = integrations.current.chatProvider("lmstudio") else { throw Abort(.notFound) }
        try await request.require(.chat)
        return provider
    }
    protected.get("lm", "v1", "models") { request async throws in
        try await (try await lmStudio(request)).upstream.forward(request, path: "/v1/models")
    }
    protected.on(.POST, "lm", "v1", "chat", "completions", body: .collect(maxSize: "16mb")) { request async throws -> Response in
        let provider = try await lmStudio(request)
        let device = try request.device
        let json = request.body.data.flatMap { try? JSONSerialization.jsonObject(with: Data($0.readableBytesView)) as? [String: Any] } ?? [:]
        request.markUsageRecorded()
        let recorder: ChatRecorder? = ChatRecorder(store: core.store, device: device,
            model: json["model"] as? String ?? "", integrationID: provider.id, request: json)
        do { return try await provider.upstream.forward(request, path: "/v1/chat/completions", recorder: recorder) }
        catch { recorder?.finish(error: (error as? HubError)?.message ?? error.localizedDescription); throw error }
    }

    @Sendable func comfy(_ request: Request) async throws -> ComfyUIProvider {
        guard let provider = integrations.current.image.first else { throw Abort(.notFound) }
        let device = try request.device
        guard Capability.workflowCapabilities.contains(where: { device.allows($0.rawValue) }) else {
            throw HubError(.forbidden, "forbidden", "This device may not use image workflows; allow it in LocalHub › Devices")
        }
        return provider
    }
    for path in ComfyUIProvider.getPaths {
        protected.on(.GET, [PathComponent.constant("comfy")] + components(path)) { request async throws in
            try await (try await comfy(request)).upstream.forward(request, path: "/\(path)")
        }
    }
    protected.get("comfy", "object_info", ":node") { request async throws in
        let node = try safeSegment(request.parameters.get("node"))
        return try await (try await comfy(request)).upstream.forward(request, path: "/object_info/\(node)")
    }
    protected.get("comfy", "history", ":id") { request async throws in
        guard let id = request.parameters.get("id"), UUID(uuidString: id) != nil else { throw Abort(.badRequest) }
        return try await (try await comfy(request)).upstream.forward(request, path: "/history/\(id)")
    }
    for path in ComfyUIProvider.postPaths {
        protected.on(.POST, [PathComponent.constant("comfy")] + components(path)) { request async throws in
            let provider = try await comfy(request)
            if path == "prompt" { request.markUsageRecorded() }
            let recorder: ChatRecorder? = path == "prompt" ? ChatRecorder(store: core.store, device: try request.device,
                model: provider.id, integrationID: provider.id, request: [:], capability: "workflow") : nil
            do { return try await provider.upstream.forward(request, path: "/\(path)", recorder: recorder) }
            catch { recorder?.finish(error: error.localizedDescription); throw error }
        }
    }

    registerMCP(protected.grouped("mcp"), mcp, store: core.store)
}

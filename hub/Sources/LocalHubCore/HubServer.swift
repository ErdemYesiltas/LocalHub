import Foundation
import enum MCP.Value
import NIOSSL
import Vapor

public let hubVersion = "0.1.0"
public let hubProtocol = 2

extension PairingResult: Content {}
extension MCPToolsResponse: Content {}
extension MCPCallResponse: Content {}

struct HubInfo: Content { let service: String; let version: String; let protocolVersion: Int; let id: String; let name: String }
struct PairRequest: Content { let code: String; let deviceName: String; let app: String?; let scopes: [String]? }
struct SessionInfo: Content { let deviceID: String; let name: String; let app: String; let scopes: [String] }
struct MCPServerSummary: Content { let id: String; let transport: String; let allowedTools: [String] }
struct ToolRequest: Content { let name: String; let arguments: [String: Value] }

private struct DeviceKey: StorageKey { typealias Value = PairedDevice }

extension Request {
    var device: PairedDevice {
        get throws {
            guard let device = storage[DeviceKey.self] else { throw Abort(.unauthorized) }
            return device
        }
    }


}

struct DeviceAuthentication: AsyncMiddleware {
    let authority: PairingAuthority
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let device = await authority.device(for: request.headers.bearerAuthorization?.token) else {
            throw HubError(.unauthorized, "unauthorized", "Pair this device with LocalHub first")
        }
        request.storage[DeviceKey.self] = device
        return try await next.respond(to: request)
    }
}

/// Refuses anything that is not loopback / private LAN, even if a router
/// forwards the port to this Mac.
struct LocalNetworkOnly: AsyncMiddleware {
    let allowVPN: Bool
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let ip = request.remoteAddress?.ipAddress, LocalNetwork.isLocal(ip) || (allowVPN && LocalNetwork.isVPN(ip)) else {
            throw HubError(.forbidden, "forbidden", "LocalHub only accepts devices on the local network")
        }
        return try await next.respond(to: request)
    }
}

func configureHub(_ app: Application, core: HubCore, settings: HubSettings, mcp: MCPRegistry) throws {
    app.http.server.configuration.hostname = settings.hostname
    app.http.server.configuration.port = settings.port
    let tls = TLSConfiguration.makeServerConfiguration(
        certificateChain: try NIOSSLCertificate.fromPEMFile(core.certificate.certificate.path).map { .certificate($0) },
        privateKey: .privateKey(try NIOSSLPrivateKey(file: core.certificate.privateKey.path, format: .pem)))
    _ = try NIOSSLContext(configuration: tls)  // fail at launch, not on the first handshake
    app.http.server.configuration.tlsConfiguration = tls
    app.routes.defaultMaxBodySize = "16mb"
    app.middleware = Middlewares()
    app.middleware.use(HubErrorMiddleware())
    app.middleware.use(LocalNetworkOnly(allowVPN: settings.allowVPN))
    app.storage[PermissionsKey.self] = core.permissions

    let authority = core.authority
    let integrations = core.integrations
    let v2 = app.grouped("v2")

    v2.get("hub") { _ in
        HubInfo(service: "localhub", version: hubVersion, protocolVersion: hubProtocol,
            id: core.identity.id, name: core.identity.name)
    }
    v2.get("openapi.yaml") { _ in
        Response(status: .ok, headers: ["Content-Type": "application/yaml; charset=utf-8"], body: .init(string: openAPISpec))
    }
    v2.post("pair") { request async throws -> PairingResult in
        let input = try request.content.decode(PairRequest.self)
        return try await pair(core, input, app: input.app ?? "unknown")
    }

    let protected = app.grouped(DeviceAuthentication(authority: authority)).grouped(UsageFailureMiddleware(store: core.store))
    let pv2 = protected.grouped("v2")

    pv2.get("session") { request async throws -> SessionInfo in
        let device = try request.device
        return SessionInfo(deviceID: device.id, name: device.name, app: device.app, scopes: device.scopes)
    }
    pv2.delete("session") { request async throws -> HTTPStatus in
        try await authority.revoke(try request.device.id)
        return .noContent
    }
    // One stream per device for everything that concerns it: its jobs and its permissions.
    // `event: job` (job object), `event: session` (new scopes), `event: revoked` (then the stream ends).
    pv2.get("events") { request async throws -> Response in
        let device = try request.device
        let jobUpdates = await core.jobs.allUpdates()
        let deviceUpdates = await authority.events()
        let encoder = JSONEncoder()
        let (merged, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(128))
        let forwardJobs = Task {
            for await job in jobUpdates where job.deviceID == device.id {
                continuation.yield("event: job\ndata: \(String(decoding: try encoder.encode(JobObject(job)), as: UTF8.self))\n\n")
            }
        }
        let forwardDevice = Task {
            for await event in deviceUpdates {
                switch event {
                case .updated(let changed) where changed.id == device.id:
                    let body = SessionInfo(deviceID: changed.id, name: changed.name, app: changed.app, scopes: changed.scopes)
                    continuation.yield("event: session\ndata: \(String(decoding: try encoder.encode(body), as: UTF8.self))\n\n")
                case .revoked(let id) where id == device.id:
                    continuation.yield("event: revoked\ndata: {}\n\n")
                    continuation.finish()
                default: break
                }
            }
        }
        let heartbeat = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(25))
                continuation.yield(": ping\n\n")
            }
        }
        continuation.onTermination = { _ in forwardJobs.cancel(); forwardDevice.cancel(); heartbeat.cancel() }
        return Response(status: .ok, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
            body: .init(managedAsyncStream: { writer in
                defer { continuation.finish() }
                try await writer.writeBuffer(ByteBuffer(string: ": connected\n\n"))
                for await chunk in merged { try await writer.writeBuffer(ByteBuffer(string: chunk)) }
            }))
    }

    pv2.get("profiles") { request async throws -> Response in
        let device = try request.device
        let profiles = try core.store.settings().workProfiles.map { profile in
            var visible = profile
            visible.models = profile.models.filter { device.allows($0.key) }
            return visible
        }
        return Response(status: .ok, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
            body: .init(data: try JSONEncoder().encode(profiles)))
    }

    pv2.get("integrations") { request async throws -> [ProviderStatus] in
        let device = try request.device
        return await integrations.current.statuses { integration in
            integration.kind.capabilities.contains { device.allows($0.rawValue) }
        }
    }

    // OpenAI-compatible surface: any OpenAI SDK with baseURL `https://<hub>/v1`
    // and a pinned transport works unchanged.
    protected.get("v1", "models") { request async throws -> OpenAIList<HubModel> in
        let device = try request.device
        let chat = device.allows(Capability.chat.rawValue) ? try await integrations.current.chatModels() : []
        return OpenAIList(data: chat + integrations.templateModels { device.allows($0.rawValue) })
    }
    protected.on(.POST, "v1", "chat", "completions", body: .collect(maxSize: "16mb")) { request async throws -> Response in
        try await request.require(.chat)
        guard let buffer = request.body.data,
              var json = try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any] else {
            throw HubError(.badRequest, "bad_request", "Expected a chat completion body")
        }
        let device = try request.device
        try applyWorkProfile(to: &json, capability: .chat, device: device, settings: core.store.settings())
        guard let model = json["model"] as? String, !model.isEmpty, model.count <= 256 else {
            throw HubError(.badRequest, "bad_request", "Choose a model or a work profile with a chat model")
        }
        request.markUsageRecorded()
        let recorder: ChatRecorder? = ChatRecorder(store: core.store, device: device, model: model,
            integrationID: String(model.split(separator: "/").first ?? ""), request: json)
        let provider: OpenAICompatibleProvider
        let upstreamModel: String
        do { (provider, upstreamModel) = try await integrations.current.route(model: model) }
        catch { recorder?.finish(error: (error as? HubError)?.message ?? error.localizedDescription); throw error }
        if let servers = json["mcp_servers"] as? [String], !servers.isEmpty {
            do {
                return try await chatWithTools(request, body: json, servers: Array(servers.prefix(8)), device: device,
                    provider: provider, upstreamModel: upstreamModel, mcp: mcp, recorder: recorder)
            } catch {
                recorder?.finish(error: (error as? HubError)?.message ?? error.localizedDescription)
                throw error
            }
        }
        json.removeValue(forKey: "mcp_servers")
        json["model"] = upstreamModel
        do {
            return try await provider.upstream.forward(request, path: "/v1/chat/completions",
                body: try JSONSerialization.data(withJSONObject: json), recorder: recorder)
        } catch {
            recorder?.finish(error: (error as? HubError)?.message ?? error.localizedDescription)
            throw error
        }
    }

    protected.on(.POST, "v1", "embeddings", body: .collect(maxSize: "16mb")) { request async throws -> Response in
        try await request.require(.embeddings)
        guard let buffer = request.body.data,
              var json = try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any], json["input"] != nil else {
            throw HubError(.badRequest, "bad_request", "Expected an embeddings body with input")
        }
        try applyWorkProfile(to: &json, capability: .embeddings, device: request.device, settings: core.store.settings())
        guard let model = json["model"] as? String, !model.isEmpty, model.count <= 256 else {
            throw HubError(.badRequest, "bad_request", "Choose a model or a work profile with an embedding model")
        }
        request.markUsageRecorded()
        let recorder: ChatRecorder? = ChatRecorder(store: core.store, device: try request.device, model: model,
            integrationID: String(model.split(separator: "/").first ?? ""), request: json, capability: "embeddings")
        do {
            let (provider, upstreamModel) = try await integrations.current.route(model: model)
            json["model"] = upstreamModel
            return try await provider.upstream.forward(request, path: "/v1/embeddings", body: try JSONSerialization.data(withJSONObject: json), recorder: recorder)
        } catch { recorder?.finish(error: (error as? HubError)?.message ?? error.localizedDescription); throw error }
    }

    registerCapabilityRoutes(protected, core: core)
    registerMCP(pv2.grouped("mcp"), mcp, store: core.store)
    if settings.legacyV1 { registerLegacyV1(app, protected, core: core, mcp: mcp) }
}

struct OpenAIList<T: Content>: Content {
    var object = "list"
    let data: [T]
}

func pair(_ core: HubCore, _ input: PairRequest, app: String) async throws -> PairingResult {
    do {
        let settings = try core.store.settings()
        let grantable = settings.grantedOnPairing
        return try await core.authority.pair(code: input.code, deviceName: input.deviceName, app: app,
            requestedScopes: input.scopes, grantable: grantable, profile: settings.pairingProfile)
    } catch PairingError.tooManyAttempts {
        throw HubError(.tooManyRequests, "too_many_attempts", "Too many wrong codes; open a new pairing window on the Mac")
    } catch PairingError.closed {
        throw HubError(.gone, "pairing_closed", "No pairing window is open; choose Pair New Device on the Mac")
    } catch PairingError.invalidName {
        throw HubError(.badRequest, "bad_request", "Device and app names must be 1–80 characters")
    } catch {
        throw HubError(.unauthorized, "wrong_code", "Wrong pairing code")
    }
}

func components(_ path: String) -> [PathComponent] {
    path.split(separator: "/").map { .constant(String($0)) }
}

func safeSegment(_ value: String?) throws -> String {
    guard let value, !value.isEmpty, value.count <= 128, value != ".", value != "..",
          !value.contains("/"), !value.contains("\\"),
          !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Abort(.badRequest) }
    return value
}

func registerMCP(_ routes: any RoutesBuilder, _ registry: MCPRegistry, store: HubStore) {
    routes.get("servers") { request async throws -> [MCPServerSummary] in
        let device = try request.device
        return await registry.servers().filter { device.allows("mcp:\($0.id)") }.map {
            MCPServerSummary(id: $0.id, transport: $0.endpoint == nil ? "stdio" : "streamable-http",
                allowedTools: $0.allowedTools)
        }
    }
    routes.get(":server", "tools") { request async throws -> MCPToolsResponse in
        let id = try safeSegment(request.parameters.get("server"))
        try await request.require(scope: "mcp:\(id)")
        do { return try await registry.listTools(serverID: id) }
        catch MCPRegistryError.unknownServer { throw Abort(.notFound) }
        catch { throw HubError(.badGateway, "upstream_error", "MCP tool discovery failed", provider: "mcp:\(id)") }
    }
    routes.post(":server", "call") { request async throws -> MCPCallResponse in
        let id = try safeSegment(request.parameters.get("server"))
        try await request.require(scope: "mcp:\(id)")
        let input = try request.content.decode(ToolRequest.self)
        request.markUsageRecorded()
        let recorder = ChatRecorder(store: store,
            device: try request.device, model: "mcp/\(id)", integrationID: id, request: [:], capability: "tools")
        defer { recorder.finish(error: "Tool call failed") }
        do {
            let result = try await registry.call(serverID: id, name: input.name, arguments: input.arguments)
            recorder.received(status: result.isError == true ? 502 : 200); recorder.finish()
            return result
        }
        catch MCPRegistryError.deniedTool { throw HubError(.forbidden, "forbidden", "Tool is not in this Mac's allowlist") }
        catch MCPRegistryError.invalidArguments { throw HubError(.badRequest, "bad_request", "Arguments do not match the tool schema") }
        catch MCPRegistryError.unknownServer { throw Abort(.notFound) }
        catch { throw HubError(.badGateway, "upstream_error", "MCP tool call failed", provider: "mcp:\(id)") }
    }
}

import Foundation
import os
import Vapor

/// Integrations as a live snapshot: the app edits them while the server runs,
/// and requests always route through the latest committed set.
public final class IntegrationRegistry: Sendable {
    private struct State: Sendable {
        var list: [ProviderConfiguration]
        var registry: ProviderRegistry
        var templates: [WorkflowTemplate]
    }
    private let store: HubStore
    private let state: OSAllocatedUnfairLock<State>

    init(store: HubStore) throws {
        self.store = store
        let list = try store.integrations()
        state = OSAllocatedUnfairLock(initialState: State(list: list, registry: ProviderRegistry(list), templates: try store.templates()))
    }

    public var list: [ProviderConfiguration] { state.withLock { $0.list } }
    public var current: ProviderRegistry { state.withLock { $0.registry } }
    public var templates: [WorkflowTemplate] { state.withLock { $0.templates } }

    public func save(_ integration: ProviderConfiguration) throws {
        try store.save(integration)
        try reload()
    }

    /// Removes the integration and the workflow templates that ran on it.
    public func delete(_ id: String) throws {
        for template in templates where template.integrationID == id { try store.deleteTemplate(template.id) }
        try store.deleteIntegration(id)
        try reload()
    }

    public func save(_ template: WorkflowTemplate) throws {
        guard list.contains(where: { $0.id == template.integrationID && $0.kind == .comfyui }) else {
            throw ConfigurationError.invalid("Choose a ComfyUI integration for this workflow")
        }
        try store.save(template)
        try reload()
    }

    public func deleteTemplate(_ id: String) throws {
        try store.deleteTemplate(id)
        try reload()
    }

    private func reload() throws {
        let list = try store.integrations()
        let templates = try store.templates()
        state.withLock { $0 = State(list: list, registry: ProviderRegistry(list), templates: templates) }
    }

    /// Templates as OpenAI model entries: `<integration>/<template>`.
    func templateModels(allowed: (Capability) -> Bool) -> [HubModel] {
        templates.filter { allowed($0.capability) }.map {
            HubModel(id: "\($0.integrationID)/\($0.id)", owned_by: $0.integrationID, provider: $0.integrationID,
                upstream_id: $0.id, capabilities: [$0.capability.rawValue])
        }
    }

    /// The template for a capability: the named model, else the Mac's default, else the only one.
    public func resolve(_ capability: Capability, model: String?, defaults: [String: String]) throws -> (WorkflowTemplate, ProviderConfiguration) {
        let candidates = templates.filter { $0.capability == capability }
        let wanted = model ?? defaults[capability.rawValue]
        let template: WorkflowTemplate?
        if let wanted {
            template = candidates.first { "\($0.integrationID)/\($0.id)" == wanted || $0.id == wanted }
            guard template != nil else {
                throw HubError(.notFound, "model_not_found", "No \(capability.title.lowercased()) workflow named \(wanted); see /v1/models")
            }
        } else {
            guard candidates.count == 1 else {
                throw HubError(.notFound, "capability_unavailable", candidates.isEmpty
                    ? "No workflow on this Mac can \(capability.title.lowercased()) yet; add one in LocalHub › Workflows"
                    : "Several workflows can \(capability.title.lowercased()); pass a model or choose a default in LocalHub")
            }
            template = candidates[0]
        }
        guard let template, let integration = list.first(where: { $0.id == template.integrationID }) else {
            throw HubError(.notFound, "capability_unavailable", "The workflow's ComfyUI integration was removed")
        }
        return (template, integration)
    }
}

/// Everything that outlives a server restart: identity, certificate, database,
/// devices and integrations. The app and the CLI each own one.
public final class HubCore: Sendable {
    public let directory: URL
    public let store: HubStore
    public let identity: HubIdentity
    public let certificate: LocalCertificate
    public let authority: PairingAuthority
    public let integrations: IntegrationRegistry
    public let files: FileStore
    public let jobs: JobRunner
    public let permissions: PermissionBroker

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        self.directory = directory
        store = try HubStore.open(directory: directory)
        identity = try HubIdentity.load(directory: directory)
        certificate = try LocalCertificate(directory: directory)
        authority = try PairingAuthority(store: store)
        integrations = try IntegrationRegistry(store: store)
        files = try FileStore(store: store, directory: directory.appendingPathComponent("files"))
        permissions = PermissionBroker(authority: authority, store: store)
        jobs = JobRunner(store: store, files: files, integrations: integrations)
        let jobs = jobs
        Task { await jobs.resumeInterrupted() }
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalHub")
    }

    /// The address clients should use: the first private LAN IPv4 when listening on the network.
    public func advertisedAddress(settings: HubSettings, port: Int) -> String {
        let host = settings.lanEnabled ? (PairingInvite.lanAddresses().first ?? "127.0.0.1") : "127.0.0.1"
        return "https://\(host):\(port)"
    }

    /// Deletes chat logs past the retention period.
    @discardableResult
    public func purgeExpiredChatLogs(now: Date = Date()) -> Int {
        guard let days = try? store.settings().retentionDays else { return 0 }
        return (try? store.purgeChatLogs(olderThan: now.addingTimeInterval(-Double(days) * 86_400))) ?? 0
    }

    @discardableResult
    public func purgeExpiredUsage(now: Date = Date()) -> Int {
        guard let days = try? store.settings().usageRetentionDays else { return 0 }
        return (try? store.purgeUsage(olderThan: now.addingTimeInterval(-Double(days) * 86_400))) ?? 0
    }

    public func invite(address: String, window: PairingWindow) -> String {
        PairingInvite.uri(address: address, fingerprint: certificate.fingerprint, code: window.code,
            hubID: identity.id, hubName: identity.name)
    }
}

/// Owns the Vapor application. Settings that change the listener (port, LAN,
/// legacy routes, MCP servers) apply through `restart`.
public actor HubServer {
    public let core: HubCore
    private var app: Application?
    private var mcp: MCPRegistry?
    private var maintenance: Task<Void, Never>?
    private var bonjour: BonjourAdvertiser?
    public private(set) var port: Int?

    public init(core: HubCore) { self.core = core }

    public var isRunning: Bool { app != nil }

    /// `portOverride: 0` binds an ephemeral port (tests).
    public func start(settings: HubSettings, portOverride: Int? = nil) async throws {
        guard app == nil else { return }
        if portOverride == nil { try settings.validate() }
        let mcp = MCPRegistry(configurations: settings.mcpServers)
        let app = try await Application.make(Environment(name: "production", arguments: ["localhub"]))
        do {
            try configureHub(app, core: core, settings: settings, mcp: mcp)
            if let portOverride { app.http.server.configuration.port = portOverride }
            try await app.server.start(address: nil)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        self.app = app
        self.mcp = mcp
        port = app.http.server.shared.localAddress?.port ?? settings.port
        if settings.lanEnabled, let port {
            bonjour = BonjourAdvertiser(identity: core.identity, fingerprint: core.certificate.fingerprint, port: port)
        }
        let core = core
        maintenance = Task.detached(priority: .background) {
            while !Task.isCancelled {
                core.purgeExpiredChatLogs()
                core.purgeExpiredUsage()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    public func stop() async {
        maintenance?.cancel()
        maintenance = nil
        bonjour?.stop()
        bonjour = nil
        guard let app else { return }
        await app.server.shutdown()
        await mcp?.shutdown()
        try? await app.asyncShutdown()
        self.app = nil
        mcp = nil
        port = nil
    }

    public func restart(settings: HubSettings) async throws {
        await stop()
        try await start(settings: settings)
    }
}

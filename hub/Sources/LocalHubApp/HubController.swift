import Foundation
import LocalHubCore
import Observation
import ServiceManagement

enum ServerState: Equatable {
    case stopped, starting, running(port: Int), failed(String)
}

struct PlaygroundIntent {
    let capability: Capability
    let providerID: String
}

/// The app's single source of UI state. The hub itself runs in-process: no
/// admin API, the UI calls LocalHubCore directly.
@MainActor @Observable
final class HubController {
    let core: HubCore
    let server: HubServer
    private let preferences: UserDefaults
    private(set) var serverState: ServerState = .stopped
    private(set) var settings: HubSettings
    /// Paired devices, without the app's own Playground device.
    private(set) var devices: [PairedDevice] = []
    private var playground: PlaygroundClient?
    private var playgroundConnection: Task<PlaygroundClient, any Error>?
    private var playgroundGeneration = UUID()
    private(set) var stopping = false
    private(set) var integrations: [ProviderConfiguration] = []
    private(set) var statuses: [String: ProviderStatus] = [:]
    private(set) var templates: [WorkflowTemplate] = []
    /// Integration id → ComfyUI's torch device (`mps`, `cuda`, `cpu`), for model compatibility warnings.
    private(set) var comfyDevices: [String: String] = [:]

    func refreshComfyDevices() async {
        for comfy in integrations where comfy.kind == .comfyui {
            if let device = await ComfyLibrary(integration: comfy).deviceType() { comfyDevices[comfy.id] = device }
        }
    }
    private(set) var files: [HubFile] = []
    private(set) var jobs: [HubJob] = []
    private(set) var chatLogs: [ChatLog] = []
    var chatSearch = ""
    var chatDevice: String?
    private(set) var pairingWindow: PairingWindow?
    private(set) var permissionRequests: [PermissionRequest] = []
    /// Address put in the QR: a LAN or VPN IP; `nil` picks the first LAN address.
    var inviteHost: String?
    private(set) var lastPaired: PairedDevice?
    var errorMessage: String?
    var playgroundIntent: PlaygroundIntent?
    var selectedJobID: String?
    var requestedSection: SidebarItem?

    func replay(_ job: HubJob, variation: Bool) async throws -> HubJob {
        guard isRunning else { throw ConfigurationError.invalid("Start the hub before replaying a recipe") }
        let device = try await localPlaygroundDevice()
        let result = try await core.jobs.replay(job.id, deviceID: nil, as: device, variation: variation, settings: settings)
        selectedJobID = result.id
        return result
    }

    private func localPlaygroundDevice() async throws -> PairedDevice {
        _ = try await playgroundClient()
        guard let device = await core.authority.listDevices().first(where: { $0.app == PairingAuthority.playgroundApp }) else {
            throw ConfigurationError.invalid("The local Playground session is unavailable; restart the hub and try again")
        }
        return device
    }

    func testWorkflow(_ template: WorkflowTemplate, prompt: String, input: JobInput?) async throws -> HubJob {
        try template.validate()
        guard let integration = integrations.first(where: { $0.id == template.integrationID }) else {
            throw ConfigurationError.invalid("Choose a ComfyUI integration first")
        }
        let device = try await localPlaygroundDevice()
        var request = WorkflowJobRequest(prompt: prompt)
        if template.slot(.seed) != nil { request.seed = 42 }
        if template.capability == .imageCreate {
            if template.slot(.steps) != nil { request.steps = 4 }
            if template.slot(.width) != nil { request.width = 512 }
            if template.slot(.height) != nil { request.height = 512 }
        }
        if let required = template.capability.requiredInput ?? (template.capability == .model3DCreate ? .image : nil) {
            guard let input else { throw ConfigurationError.invalid("Choose an input file first") }
            switch required {
            case .image: request.image = input; if template.slot(.mask) != nil { request.mask = input }
            case .audio: request.audio = input
            case .video: request.video = input
            default: break
            }
        }
        let result = try await core.jobs.submit(device: device, template: template, integration: integration,
            request: request, settings: settings)
        selectedJobID = result.id
        return result
    }
    private(set) var playgroundModels: [PlaygroundModel] = []
    private(set) var loadingModels = false
    private(set) var modelError: String?
    private(set) var hasCompletedPlaygroundRun = false
    private(set) var setupDismissed = false
    private var modelRefreshID = UUID()

    private var preferencePrefix: String { "localhub.\(core.identity.id)." }
    private var isSnapshot: Bool { CommandLine.arguments.contains("--snapshot") }

    init(core: HubCore, preferences: UserDefaults = .standard) {
        self.core = core
        self.preferences = preferences
        server = HubServer(core: core)
        settings = (try? core.store.settings()) ?? HubSettings()
        integrations = core.integrations.list
        templates = core.integrations.templates
        if !isSnapshot {
            hasCompletedPlaygroundRun = preferences.bool(forKey: preferencePrefix + "playgroundSucceeded")
            setupDismissed = preferences.bool(forKey: preferencePrefix + "setupDismissed")
        }
        Task { await self.listen() }
        Task { await self.followJobs() }
        Task { await self.followPermissions() }
    }

    convenience init() throws {
        self.init(core: try HubCore(directory: HubCore.defaultDirectory))
    }

    var address: String {
        let port = { if case .running(let p) = serverState { p } else { settings.port } }()
        if let inviteHost, settings.lanEnabled { return "https://\(inviteHost):\(port)" }
        return core.advertisedAddress(settings: settings, port: port)
    }

    /// Hosts a device could reach this Mac at: LAN addresses, plus VPN ones when allowed.
    var reachableHosts: [String] {
        guard settings.lanEnabled else { return [] }
        return PairingInvite.lanAddresses() + (settings.allowVPN ? PairingInvite.vpnAddresses() : [])
    }

    // MARK: Permission requests

    private func followPermissions() async {
        for await event in await core.permissions.events() {
            switch event {
            case .requested(let request):
                permissionRequests.append(request)
                Notifier.notify(title: "\(request.deviceName) asks to \(request.title)",
                    body: "Open LocalHub to allow or deny (\(request.app)).", id: request.id)
            case .resolved(let id):
                permissionRequests.removeAll { $0.id == id }
            }
        }
    }

    func answer(_ request: PermissionRequest, allow: Bool) {
        Task { await core.permissions.answer(request.id, allow: allow); await refreshDevices() }
    }

    var isRunning: Bool { if case .running = serverState { !stopping } else { false } }

    var activeJobs: [HubJob] { jobs.filter { !$0.status.isFinished } }

    /// A reachable app is not enough: chat needs a discovered model and media needs a workflow.
    func capabilities(for integration: ProviderConfiguration) -> [Capability] {
        guard isRunning, statuses[integration.id]?.state == "running" else { return [] }
        switch integration.kind {
        case .openai:
            return Capability.allCases.filter { capability in
                playgroundModels.contains { $0.provider == integration.id && $0.capabilities.contains(capability.rawValue) }
            }
        case .comfyui:
            return Capability.allCases.filter { capability in
                templates.contains { $0.integrationID == integration.id && $0.capability == capability
                    && $0.unsupportedModelWarning(device: comfyDevices[integration.id]) == nil }
            }
        case .whisper: return [.audioTranscribe]
        }
    }

    var readyCapabilities: [Capability] {
        let ready = Set(integrations.flatMap { capabilities(for: $0) })
        return Capability.allCases.filter { ready.contains($0) }
    }

    func completePlaygroundRun() {
        hasCompletedPlaygroundRun = true
        if !isSnapshot { preferences.set(true, forKey: preferencePrefix + "playgroundSucceeded") }
    }

    func dismissSetup() {
        setupDismissed = true
        if !isSnapshot { preferences.set(true, forKey: preferencePrefix + "setupDismissed") }
    }

    func refreshModels() async {
        guard isRunning, !loadingModels else { return }
        let refreshID = UUID()
        modelRefreshID = refreshID
        loadingModels = true
        modelError = nil
        do {
            let models = try await playgroundClient().models()
            guard modelRefreshID == refreshID, isRunning else { return }
            playgroundModels = models
        } catch {
            guard modelRefreshID == refreshID, isRunning else { return }
            playgroundModels = []
            modelError = Self.describe(error)
        }
        if modelRefreshID == refreshID { loadingModels = false }
    }

    // MARK: Server

    func start(portOverride: Int? = nil) async {
        guard serverState != .starting, !isRunning, !stopping else { return }
        serverState = .starting
        do {
            try await server.start(settings: settings, portOverride: portOverride)
            serverState = .running(port: await server.port ?? settings.port)
        } catch {
            serverState = .failed(Self.describe(error))
        }
        await refreshDevices()
        await refreshStatuses()
        await refreshModels()
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        playgroundGeneration = UUID()
        playgroundConnection?.cancel()
        playgroundConnection = nil
        modelRefreshID = UUID()
        playgroundModels = []
        loadingModels = false
        modelError = nil
        playground = nil
        await server.stop()
        serverState = .stopped
    }

    func apply(_ new: HubSettings) async {
        do {
            try core.store.save(new)
        } catch {
            errorMessage = Self.describe(error)
            return
        }
        let needsRestart = new.port != settings.port || new.lanEnabled != settings.lanEnabled
            || new.legacyV1 != settings.legacyV1 || new.mcpServers != settings.mcpServers || new.allowVPN != settings.allowVPN
        let retentionShortened = new.retentionDays < settings.retentionDays
        let usageShortened = new.usageRetentionDays < settings.usageRetentionDays
        settings = new
        await core.jobs.queueSettingsChanged()
        if retentionShortened { core.purgeExpiredChatLogs(); refreshChatLogs() }
        if usageShortened { core.purgeExpiredUsage() }
        if needsRestart && isRunning {
            await stop()
            await start()
        }
    }

    // MARK: Pairing

    func openPairing() async {
        pairingWindow = await core.authority.openWindow()
        lastPaired = nil
    }

    func closePairing() async {
        await core.authority.closeWindow()
        pairingWindow = nil
    }

    var invite: String? {
        pairingWindow.map { core.invite(address: address, window: $0) }
    }

    private func listen() async {
        let events = await core.authority.events()
        await refreshDevices()
        for await event in events {
            switch event {
            case .paired(let device):
                lastPaired = device
                pairingWindow = nil
            case .devicesChanged, .updated, .revoked:
                break
            }
            await refreshDevices()
        }
    }

    // MARK: Devices

    func refreshDevices() async {
        devices = await core.authority.listDevices().filter { $0.app != PairingAuthority.playgroundApp }
    }

    // MARK: Playground

    /// A client for the app's own hub over loopback, through the real API, with every permission.
    func playgroundClient() async throws -> PlaygroundClient {
        guard case .running(let port) = serverState, !stopping else {
            throw ConfigurationError.invalid("Start the hub to use the Playground")
        }
        if let playground { return playground }
        let generation = playgroundGeneration
        if let pending = playgroundConnection {
            let client = try await pending.value
            guard generation == playgroundGeneration, isRunning else { throw CancellationError() }
            return client
        }
        let scopes = Capability.allCases.map(\.rawValue) + settings.mcpServers.map { "mcp:\($0.id)" }
        let core = core
        let connection = Task {
            let (token, deviceID) = try await core.authority.issuePlaygroundToken(scopes: scopes)
            try Task.checkCancellation()
            return try await makePlaygroundClient(address: URL(string: "https://127.0.0.1:\(port)")!,
                fingerprint: core.certificate.fingerprint, token: token, deviceID: deviceID, scopes: scopes,
                hubID: core.identity.id, hubName: core.identity.name)
        }
        playgroundConnection = connection
        defer { if generation == playgroundGeneration { playgroundConnection = nil } }
        let client = try await connection.value
        guard generation == playgroundGeneration, isRunning else { throw CancellationError() }
        playground = client
        return client
    }

    func usage(days: Int) -> UsageReport? {
        try? core.store.usage(since: Calendar.current.date(byAdding: .day, value: -days, to: Date())!)
    }

    func revoke(_ device: PairedDevice) async {
        do { try await core.authority.revoke(device.id) } catch { errorMessage = Self.describe(error) }
    }

    func setScope(_ scope: String, enabled: Bool, for device: PairedDevice) async {
        do {
            try await core.authority.update(device.id) { d in
                d.profileID = nil
                d.scopes.removeAll { $0 == scope }
                if enabled { d.scopes.append(scope) }
            }
        } catch { errorMessage = Self.describe(error) }
    }

    func setLogging(_ enabled: Bool, for device: PairedDevice) async {
        do { try await core.authority.update(device.id) { $0.logging = enabled; $0.profileID = nil } } catch { errorMessage = Self.describe(error) }
    }

    func saveProfile(_ profile: DeviceProfile, isNew: Bool) throws {
        try profile.validate()
        var next = settings
        if isNew, next.deviceProfiles.contains(where: { $0.id == profile.id }) { throw ConfigurationError.invalid("This device profile ID already exists") }
        next.deviceProfiles.removeAll { $0.id == profile.id }; next.deviceProfiles.append(profile)
        try core.store.save(next); settings = next
    }

    func saveProfile(_ profile: WorkProfile, isNew: Bool) throws {
        try profile.validate()
        var next = settings
        if isNew, next.workProfiles.contains(where: { $0.id == profile.id }) { throw ConfigurationError.invalid("This work profile ID already exists") }
        next.workProfiles.removeAll { $0.id == profile.id }; next.workProfiles.append(profile)
        try core.store.save(next); settings = next
    }

    func deleteProfile(_ profile: DeviceProfile) throws {
        var next = settings
        next.deviceProfiles.removeAll { $0.id == profile.id }
        if next.defaultDeviceProfileID == profile.id { next.defaultDeviceProfileID = nil }
        try core.store.save(next); settings = next
    }

    func deleteProfile(_ profile: WorkProfile) async throws {
        for device in await core.authority.listDevices() where device.workProfileID == profile.id {
            try await core.authority.update(device.id) { $0.workProfileID = nil }
        }
        var next = settings; next.workProfiles.removeAll { $0.id == profile.id }
        try core.store.save(next); settings = next
        await refreshDevices()
    }

    func applyProfile(_ profileID: String, to device: PairedDevice) async {
        guard let profile = settings.deviceProfiles.first(where: { $0.id == profileID }) else { return }
        do {
            try profile.validate()
            try await core.authority.update(device.id) { profile.apply(to: &$0) }
            await refreshDevices()
        } catch { errorMessage = Self.describe(error) }
    }

    func setDeviceLimits(_ device: PairedDevice, quotaMiB: Int, maxJobs: Int, preserveQuota: Bool = false) async {
        guard (0...1_048_576).contains(quotaMiB), (1...16).contains(maxJobs) else {
            errorMessage = "Quota must be 0–1048576 MiB and job limit must be 1–16"; return
        }
        do {
            let quota = preserveQuota ? device.effectiveFileQuota(settings) : quotaMiB * 1024 * 1024
            try await core.authority.update(device.id) { d in
                d.fileQuotaBytes = quota; d.maxJobs = maxJobs; d.profileID = nil
            }
            await refreshDevices()
        } catch { errorMessage = Self.describe(error) }
    }

    func setWorkProfile(_ id: String?, for device: PairedDevice) async {
        guard id == nil || settings.workProfiles.contains(where: { $0.id == id }) else { return }
        do { try await core.authority.update(device.id) { $0.workProfileID = id }; await refreshDevices() }
        catch { errorMessage = Self.describe(error) }
    }

    /// Scopes the UI offers: every capability, plus configured MCP servers.
    var availableScopes: [(id: String, name: String)] {
        Capability.allCases.map { ($0.rawValue, $0.title) } + settings.mcpServers.map { ("mcp:\($0.id)", "MCP · \($0.id)") }
    }

    func deviceName(_ id: String?) -> String {
        guard let id else { return "This Mac" }
        return devices.first { $0.id == id }?.name ?? "Removed device"
    }

    // MARK: Workflows

    func save(_ template: WorkflowTemplate) -> String? {
        do {
            try core.integrations.save(template)
            templates = core.integrations.templates
            Task { await refreshModels() }
            return nil
        } catch { return Self.describe(error) }
    }

    func delete(_ template: WorkflowTemplate) {
        do {
            try core.integrations.deleteTemplate(template.id)
            templates = core.integrations.templates
            Task { await refreshModels() }
            if settings.defaults[template.capability.rawValue] == "\(template.integrationID)/\(template.id)" {
                setDefault(nil, for: template.capability)
            }
        } catch { errorMessage = Self.describe(error) }
    }

    func setDefault(_ model: String?, for capability: Capability) {
        var next = settings
        next.defaults[capability.rawValue] = model
        Task { await apply(next) }
    }

    // MARK: MCP servers

    /// Saving restarts the listener so the new server set takes effect.
    func save(_ server: MCPServerConfiguration, replacing id: String?) async -> String? {
        do { try server.validate() } catch { return Self.describe(error) }
        var next = settings
        next.mcpServers.removeAll { $0.id == (id ?? server.id) }
        if id == nil, settings.mcpServers.contains(where: { $0.id == server.id }) {
            return "An MCP server with the ID “\(server.id)” already exists"
        }
        next.mcpServers.append(server)
        errorMessage = nil
        await apply(next)
        defer { errorMessage = nil }
        return errorMessage
    }

    func delete(_ server: MCPServerConfiguration) {
        var next = settings
        next.mcpServers.removeAll { $0.id == server.id }
        Task { await apply(next) }
    }

    // MARK: Conversations

    func refreshChatLogs() {
        let search = chatSearch.trimmingCharacters(in: .whitespaces)
        chatLogs = (try? core.store.chatLogs(deviceID: chatDevice, search: search.isEmpty ? nil : search)) ?? []
    }

    func deleteChatLog(_ log: ChatLog) {
        do { try core.store.deleteChatLog(log.id); refreshChatLogs() } catch { errorMessage = Self.describe(error) }
    }

    func deleteShownChatLogs() {
        do {
            for log in chatLogs { try core.store.deleteChatLog(log.id) }
            refreshChatLogs()
        } catch { errorMessage = Self.describe(error) }
    }

    func exportChatLogs(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(chatLogs).write(to: url, options: .atomic) } catch { errorMessage = Self.describe(error) }
    }

    // MARK: Files and jobs

    func refreshFiles() {
        files = (try? core.files.list(deviceID: nil)) ?? []
    }

    func deleteFile(_ file: HubFile) {
        do { try core.files.delete(file.id, deviceID: nil); refreshFiles() } catch { errorMessage = Self.describe(error) }
    }

    func cancel(_ job: HubJob) {
        Task { await core.jobs.cancel(job.id, deviceID: nil) }
    }

    private func followJobs() async {
        let updates = await core.jobs.allUpdates()
        jobs = await core.jobs.list(deviceID: nil, limit: 200)
        refreshFiles()
        for await job in updates {
            let previous = jobs.first { $0.id == job.id }
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
            if job.status == .completed { refreshFiles() }
            if job.previewUpdatedAt != previous?.previewUpdatedAt, let preview = await core.jobs.preview(job.id, deviceID: nil) {
                previews[job.id] = preview.data
            }
            if job.status.isFinished, previous?.status.isFinished == false {
                previews[job.id] = nil
                Notifier.jobFinished(job)
            }
        }
    }

    /// Live preview frames of running jobs, keyed by job id.
    private(set) var previews: [String: Data] = [:]

    // MARK: Integrations

    /// Returns an error message instead of throwing so editor sheets can show it inline.
    func save(_ integration: ProviderConfiguration) -> String? {
        do {
            try core.integrations.save(integration)
            integrations = core.integrations.list
            Task { await refreshStatuses(); await refreshModels() }
            return nil
        } catch { return Self.describe(error) }
    }

    func delete(_ integration: ProviderConfiguration) {
        do {
            try core.integrations.delete(integration.id)
            integrations = core.integrations.list
            templates = core.integrations.templates
            statuses[integration.id] = nil
            playgroundModels.removeAll { $0.provider == integration.id }
            var next = settings
            next.defaults = next.defaults.filter { !$0.value.hasPrefix(integration.id + "/") }
            if next != settings { Task { await apply(next) } }
        } catch { errorMessage = Self.describe(error) }
    }

    func refreshStatuses() async {
        let list = await core.integrations.current.statuses()
        statuses = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    // MARK: Login item

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Launch at login is only available from the installed LocalHub.app (\(error.localizedDescription))"
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ConfigurationError { return error.description }
        let text = String(describing: error)
        if text.contains("Address already in use") || text.contains("errno: 48") {
            return "The port is already in use by another app. Choose another port in Settings."
        }
        return error.localizedDescription
    }
}

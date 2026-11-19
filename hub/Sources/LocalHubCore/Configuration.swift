import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// Any server speaking OpenAI's `/v1/models` and `/v1/chat/completions` (LM Studio, Ollama, llama.cpp, MLX).
    case openai
    case comfyui
    /// whisper.cpp server (`/inference`) or an OpenAI-style transcription server (`/v1/audio/transcriptions`).
    case whisper
}

/// One integration: a Mac-local app the hub fronts. Stored in `hub.sqlite`, edited from the app.
public struct ProviderConfiguration: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ProviderKind
    public var name: String
    public var baseURL: String

    public init(id: String, kind: ProviderKind, name: String, baseURL: String) {
        self.id = id; self.kind = kind; self.name = name; self.baseURL = baseURL
    }

    public static let defaults = [
        ProviderConfiguration(id: "lmstudio", kind: .openai, name: "LM Studio", baseURL: "http://127.0.0.1:1234"),
        ProviderConfiguration(id: "ollama", kind: .openai, name: "Ollama", baseURL: "http://127.0.0.1:11434"),
        ProviderConfiguration(id: "comfyui", kind: .comfyui, name: "ComfyUI", baseURL: "http://127.0.0.1:8188"),
    ]

    /// Upstreams must live on this Mac: the hub fronts local apps, it never
    /// becomes a relay to arbitrary hosts.
    public func validate() throws {
        guard id.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil else {
            throw ConfigurationError.invalid("ID must start with a letter and use only a–z, 0–9 and -")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 40 else {
            throw ConfigurationError.invalid("Name must be 1–40 characters")
        }
        guard let url = URLComponents(string: baseURL), url.scheme == "http" || url.scheme == "https",
              let host = url.host, ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ConfigurationError.invalid("Address must be http(s) on this Mac, e.g. http://127.0.0.1:1234")
        }
    }
}

/// A local MCP server (stdio command) or one reached over streamable HTTP. Devices
/// only see tools in `allowedTools`, and only with the `mcp:<id>` permission.
public struct MCPServerConfiguration: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var executable: String?
    public var arguments: [String]?
    public var endpoint: String?
    public var allowedTools: [String]
    public var workingDirectory: String?

    public init(id: String, executable: String? = nil, arguments: [String]? = nil, endpoint: String? = nil,
                allowedTools: [String] = [], workingDirectory: String? = nil) {
        self.id = id; self.executable = executable; self.arguments = arguments; self.endpoint = endpoint
        self.allowedTools = allowedTools; self.workingDirectory = workingDirectory
    }

    public func validate() throws {
        guard id.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil else {
            throw ConfigurationError.invalid("MCP server ID must start with a letter and use only a–z, 0–9 and -")
        }
        switch (executable, endpoint) {
        case (let executable?, nil):
            guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
                throw ConfigurationError.invalid("Command must be the full path to an executable, e.g. /opt/homebrew/bin/npx")
            }
            if let workingDirectory, !FileManager.default.fileExists(atPath: workingDirectory) {
                throw ConfigurationError.invalid("Working folder does not exist")
            }
        case (nil, let endpoint?):
            guard let url = URLComponents(string: endpoint), let host = url.host, url.user == nil, url.password == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)) else {
                throw ConfigurationError.invalid("Endpoint must be https://, or http:// on this Mac")
            }
        default:
            throw ConfigurationError.invalid("Set either a command or an endpoint")
        }
    }
}

/// Hub-wide settings, one JSON row in `hub.sqlite`. Missing keys keep defaults
/// so older databases decode after new settings are added.
public struct HubSettings: Codable, Sendable, Equatable {
    public var port = 8790
    /// Listen on all interfaces so tablets can connect; requests are still limited to local addresses.
    public var lanEnabled = false
    /// Chat log retention (used from phase 3).
    public var retentionDays = 30
    public var usageRetentionDays = 365
    /// Also serve the ArtBlend Companion v1 routes (`/pair`, `/lm/v1/*`, `/comfy/*`, `/mcp/*`).
    public var legacyV1 = true
    /// Scopes a newly paired device receives: capabilities (`chat`, `image.edit`…)
    /// and `mcp:<id>`. `nil` grants every capability; MCP is only granted when listed here.
    public var defaultScopes: [String]?
    public var mcpServers: [MCPServerConfiguration] = []
    /// Capability → model used when a request names none, e.g. `image.edit` → `comfyui/sdxl-inpaint`.
    public var defaults: [String: String] = [:]
    public var fileQuotaBytes = 2 * 1024 * 1024 * 1024
    public var maxJobsPerDevice = 2
    /// Workflows wait in the queue until ComfyUI's Mac has this much free RAM (0 = never wait).
    public var minFreeMemoryGB = 4.0
    /// Hold requests for missing permissions and ask on the Mac instead of refusing them.
    public var askOnFirstUse = true
    /// Also accept Tailscale-style VPN addresses (100.64.0.0/10), not just the local network.
    public var allowVPN = false
    public var deviceProfiles: [DeviceProfile] = DeviceProfile.presets
    public var defaultDeviceProfileID: String?
    public var workProfiles: [WorkProfile] = WorkProfile.presets
    public var queue = QueueSettings()

    public init() {}

    public var hostname: String { lanEnabled ? "0.0.0.0" : "127.0.0.1" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HubSettings()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        lanEnabled = try c.decodeIfPresent(Bool.self, forKey: .lanEnabled) ?? d.lanEnabled
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        usageRetentionDays = try c.decodeIfPresent(Int.self, forKey: .usageRetentionDays) ?? d.usageRetentionDays
        legacyV1 = try c.decodeIfPresent(Bool.self, forKey: .legacyV1) ?? d.legacyV1
        defaultScopes = try c.decodeIfPresent([String].self, forKey: .defaultScopes)
        mcpServers = try c.decodeIfPresent([MCPServerConfiguration].self, forKey: .mcpServers) ?? []
        defaults = try c.decodeIfPresent([String: String].self, forKey: .defaults) ?? [:]
        fileQuotaBytes = try c.decodeIfPresent(Int.self, forKey: .fileQuotaBytes) ?? d.fileQuotaBytes
        maxJobsPerDevice = try c.decodeIfPresent(Int.self, forKey: .maxJobsPerDevice) ?? d.maxJobsPerDevice
        minFreeMemoryGB = try c.decodeIfPresent(Double.self, forKey: .minFreeMemoryGB) ?? d.minFreeMemoryGB
        askOnFirstUse = try c.decodeIfPresent(Bool.self, forKey: .askOnFirstUse) ?? d.askOnFirstUse
        allowVPN = try c.decodeIfPresent(Bool.self, forKey: .allowVPN) ?? d.allowVPN
        deviceProfiles = try c.decodeIfPresent([DeviceProfile].self, forKey: .deviceProfiles) ?? d.deviceProfiles
        defaultDeviceProfileID = try c.decodeIfPresent(String.self, forKey: .defaultDeviceProfileID)
        workProfiles = try c.decodeIfPresent([WorkProfile].self, forKey: .workProfiles) ?? d.workProfiles
        queue = try c.decodeIfPresent(QueueSettings.self, forKey: .queue) ?? d.queue
    }

    public func validate() throws {
        try queue.validate()
        guard (1024...65535).contains(port) else { throw ConfigurationError.invalid("Port must be 1024–65535") }
        guard (1...3650).contains(retentionDays) else { throw ConfigurationError.invalid("Retention must be 1–3650 days") }
        guard (1...3650).contains(usageRetentionDays) else { throw ConfigurationError.invalid("Usage retention must be 1–3650 days") }
        guard Set(mcpServers.map(\.id)).count == mcpServers.count else { throw ConfigurationError.invalid("Duplicate MCP server id") }
        guard (1...16).contains(maxJobsPerDevice) else { throw ConfigurationError.invalid("Jobs per device must be 1–16") }
        guard (0...512).contains(minFreeMemoryGB) else { throw ConfigurationError.invalid("Free memory must be 0–512 GB") }
        guard fileQuotaBytes >= 0 else { throw ConfigurationError.invalid("File quota must not be negative") }
        guard Set(deviceProfiles.map(\.id)).count == deviceProfiles.count, Set(workProfiles.map(\.id)).count == workProfiles.count else {
            throw ConfigurationError.invalid("Profile IDs must be unique")
        }
        for profile in deviceProfiles { try profile.validate() }
        for profile in workProfiles { try profile.validate() }
        if let defaultDeviceProfileID, !deviceProfiles.contains(where: { $0.id == defaultDeviceProfileID }) {
            throw ConfigurationError.invalid("The default device profile no longer exists")
        }
    }

    public var grantedOnPairing: [String] {
        pairingProfile?.scopes ?? defaultScopes ?? Capability.allCases.map(\.rawValue)
    }
    public var pairingProfile: DeviceProfile? { deviceProfiles.first { $0.id == defaultDeviceProfileID } }
}

public enum ConfigurationError: Error, CustomStringConvertible, LocalizedError {
    case invalid(String)
    public var description: String { switch self { case .invalid(let reason): reason } }
    public var errorDescription: String? { description }
}

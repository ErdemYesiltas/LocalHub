import Foundation

/// Applying a profile copies its policy; subsequent profile edits do not silently
/// change permissions on already-paired devices.
public struct DeviceProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var scopes: [String]
    public var logging: Bool
    public var fileQuotaBytes: Int
    public var maxJobs: Int

    public init(id: String, name: String, scopes: [String], logging: Bool, fileQuotaBytes: Int, maxJobs: Int) {
        self.id = id; self.name = name; self.scopes = scopes; self.logging = logging
        self.fileQuotaBytes = fileQuotaBytes; self.maxJobs = maxJobs
    }

    public static let presets: [DeviceProfile] = [
        DeviceProfile(id: "artblend", name: "ArtBlend", scopes: ["chat", "image.create", "image.edit", "3d.create"],
                      logging: true, fileQuotaBytes: 4 * 1024 * 1024 * 1024, maxJobs: 2),
        DeviceProfile(id: "chat", name: "Chat", scopes: ["chat", "embeddings"],
                      logging: true, fileQuotaBytes: 256 * 1024 * 1024, maxJobs: 1),
        DeviceProfile(id: "guest", name: "Guest", scopes: ["chat"],
                      logging: false, fileQuotaBytes: 64 * 1024 * 1024, maxJobs: 1),
    ]

    public func validate() throws {
        try validateProfileIdentity(id: id, name: name)
        guard (0...1_099_511_627_776).contains(fileQuotaBytes), (1...16).contains(maxJobs) else {
            throw ConfigurationError.invalid("Profile quota must be 0–1 TiB and job limit must be 1–16")
        }
        guard Set(scopes).count == scopes.count, scopes.allSatisfy({ scope in
            Capability(rawValue: scope) != nil || (scope.hasPrefix("mcp:") && String(scope.dropFirst(4)).range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil)
        }) else { throw ConfigurationError.invalid("Profile permissions contain an unknown or duplicate scope") }
    }

    public func apply(to device: inout PairedDevice, requestedScopes: [String]? = nil) {
        device.scopes = requestedScopes.map { requested in scopes.filter(requested.contains) } ?? scopes
        device.logging = logging; device.fileQuotaBytes = fileQuotaBytes; device.maxJobs = maxJobs; device.profileID = id
    }
}

public struct WorkProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var models: [String: String]
    public var steps: Int?
    public var width: Int?
    public var height: Int?
    public var negativePrompt: String?
    public var seconds: Double?
    public var fps: Double?
    public var schedule: JobSchedule?
    public var priority: Int?

    public init(id: String, name: String, models: [String: String] = [:], steps: Int? = nil,
                width: Int? = nil, height: Int? = nil, negativePrompt: String? = nil, seconds: Double? = nil, fps: Double? = nil,
                schedule: JobSchedule? = nil, priority: Int? = nil) {
        self.id = id; self.name = name; self.models = models; self.steps = steps
        self.width = width; self.height = height; self.negativePrompt = negativePrompt; self.seconds = seconds; self.fps = fps
        self.schedule = schedule; self.priority = priority
    }

    public static let presets = [
        WorkProfile(id: "draft", name: "Quick Draft", steps: 4, width: 512, height: 512),
        WorkProfile(id: "final", name: "Final Production", steps: 30, width: 1024, height: 1024),
        WorkProfile(id: "night", name: "Night Queue", steps: 30, width: 1024, height: 1024, schedule: .night, priority: -5),
    ]

    public func validate() throws {
        try validateProfileIdentity(id: id, name: name)
        guard models.allSatisfy({ Capability(rawValue: $0.key) != nil && !$0.value.isEmpty && $0.value.count <= 256 }) else {
            throw ConfigurationError.invalid("Choose valid capability model IDs")
        }
        if let steps, !(1...150).contains(steps) { throw ConfigurationError.invalid("Steps must be 1–150") }
        guard (width == nil) == (height == nil) else { throw ConfigurationError.invalid("Set both width and height, or leave both at the workflow default") }
        for dimension in [width, height].compactMap({ $0 }) where !(64...4096).contains(dimension) || dimension % 8 != 0 {
            throw ConfigurationError.invalid("Dimensions must be 64–4096 and multiples of 8")
        }
        if let seconds, !seconds.isFinite || !(0.5...600).contains(seconds) { throw ConfigurationError.invalid("Duration must be 0.5–600 seconds") }
        if let fps, !fps.isFinite || !(1...120).contains(fps) { throw ConfigurationError.invalid("Frame rate must be 1–120") }
        if let negativePrompt, negativePrompt.count > 4000 { throw ConfigurationError.invalid("Negative prompt is limited to 4000 characters") }
        if let priority, !(-10...10).contains(priority) { throw ConfigurationError.invalid("Priority must be -10–10") }
    }
}

private func validateProfileIdentity(id: String, name: String) throws {
    guard id.range(of: #"^[a-z][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil,
          !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60 else {
        throw ConfigurationError.invalid("Profile ID must use a–z, 0–9 and -, and its name must be 1–60 characters")
    }
}

extension PairedDevice {
    public func effectiveFileQuota(_ settings: HubSettings) -> Int { fileQuotaBytes ?? settings.fileQuotaBytes }
    public func effectiveMaxJobs(_ settings: HubSettings) -> Int { maxJobs ?? settings.maxJobsPerDevice }
}

extension HubSettings {
    public func workProfile(id: String?, device: PairedDevice) throws -> WorkProfile? {
        if id == "" { return nil }
        guard let selected = id ?? device.workProfileID else { return nil }
        guard let profile = workProfiles.first(where: { $0.id == selected }) else {
            throw HubError(.notFound, "profile_not_found", "No work profile named \(selected); choose one published by this Mac")
        }
        return profile
    }
}

/// Removes the hub-only profile extension before forwarding an OpenAI body.
func applyWorkProfile(to json: inout [String: Any], capability: Capability, device: PairedDevice, settings: HubSettings) throws {
    if json["profile"] is NSNull { json.removeValue(forKey: "profile") }
    if let value = json["profile"], !(value is String) { throw HubError(.badRequest, "bad_request", "profile must be a string") }
    let profile = try settings.workProfile(id: json["profile"] as? String, device: device)
    json.removeValue(forKey: "profile")
    if json["model"] == nil, let model = profile?.models[capability.rawValue] { json["model"] = model }
}

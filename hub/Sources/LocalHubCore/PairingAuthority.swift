import CryptoKit
import Foundation

public struct PairedDevice: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    /// Which client app paired, e.g. `artblend`, `olive-studio`. Display and policy only.
    public let app: String
    public let tokenHash: String
    public let createdAt: Date
    public var lastSeenAt: Date?
    public var scopes: [String]
    /// Keep chat logs for this device (phase 3).
    public var logging: Bool
    public var profileID: String?
    public var fileQuotaBytes: Int?
    public var maxJobs: Int?
    public var workProfileID: String?

    public init(id: String, name: String, app: String, tokenHash: String, createdAt: Date,
                lastSeenAt: Date? = nil, scopes: [String], logging: Bool = true) {
        self.id = id; self.name = name; self.app = app; self.tokenHash = tokenHash
        self.createdAt = createdAt; self.lastSeenAt = lastSeenAt; self.scopes = scopes; self.logging = logging
    }

    public func allows(_ scope: String) -> Bool { scopes.contains(scope) }
}

public struct PairingResult: Codable, Sendable {
    public let deviceID: String
    public let token: String
    public let scopes: [String]
}

public struct PairingWindow: Sendable, Equatable {
    public let code: String
    public let expiresAt: Date
}

public enum PairingEvent: Sendable {
    case paired(PairedDevice)
    case devicesChanged
    /// Permissions or settings of one device changed.
    case updated(PairedDevice)
    case revoked(deviceID: String)
}

public enum PairingError: Error { case closed, denied, tooManyAttempts, invalidName }

/// Issues bearer tokens against a short-lived one-time code. Only the token's
/// SHA-256 is stored; a leaked database grants nothing.
public actor PairingAuthority {
    private let store: HubStore
    private var devices: [PairedDevice]
    private var window: PairingWindow?
    private var attempts = 0
    private var lastSeenWrites: [String: Date] = [:]
    private var subscribers: [UUID: AsyncStream<PairingEvent>.Continuation] = [:]

    public init(store: HubStore) throws {
        self.store = store
        devices = try store.devices()
    }

    /// Pairing and device changes, for the app's UI. Each call is an independent subscription.
    public func events() -> AsyncStream<PairingEvent> {
        let (stream, continuation) = AsyncStream<PairingEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
    private func emit(_ event: PairingEvent) { for continuation in subscribers.values { continuation.yield(event) } }

    /// Opens a fresh window, replacing any open one ("Pair a new device").
    @discardableResult
    public func openWindow(code: String? = nil, lifetime: TimeInterval = 180) -> PairingWindow {
        let opened = PairingWindow(code: code ?? String(format: "%06d", Int.random(in: 0...999_999)),
            expiresAt: Date().addingTimeInterval(lifetime))
        window = opened
        attempts = 0
        return opened
    }

    public func closeWindow() { window = nil }
    public var currentWindow: PairingWindow? { window.flatMap { $0.expiresAt > Date() ? $0 : nil } }

    public func pair(code candidate: String, deviceName: String, app: String,
                     requestedScopes: [String]?, grantable: [String], profile: DeviceProfile? = nil) throws -> PairingResult {
        guard let open = window, Date() < open.expiresAt else { throw PairingError.closed }
        guard attempts < 10 else { window = nil; throw PairingError.tooManyAttempts }
        attempts += 1
        guard Self.constantTimeEqual(candidate, open.code) else { throw PairingError.denied }
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !appID.isEmpty, appID.count <= 64 else { throw PairingError.invalidName }
        let scopes = requestedScopes.map { requested in grantable.filter(requested.contains) } ?? grantable
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        var device = PairedDevice(id: UUID().uuidString, name: name, app: appID,
            tokenHash: Self.hash(token), createdAt: Date(), scopes: scopes)
        if let profile {
            try profile.validate()
            profile.apply(to: &device, requestedScopes: scopes)
        }
        try store.save(device)
        devices.append(device)
        window = nil
        emit(.paired(device))
        return PairingResult(deviceID: device.id, token: token, scopes: device.scopes)
    }

    /// Creates a device without a pairing window (internal use: the Playground).
    func issue(name: String, app: String, scopes: [String]) throws -> (token: String, deviceID: String) {
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        let device = PairedDevice(id: UUID().uuidString, name: name, app: app, tokenHash: Self.hash(token),
            createdAt: Date(), scopes: scopes, logging: false)
        try store.save(device)
        devices.append(device)
        emit(.devicesChanged)
        return (token, device.id)
    }

    /// Resolves a bearer token and records "last seen" (persisted at most once a minute per device).
    public func device(for token: String?) -> PairedDevice? {
        guard let token, token.count >= 32, token.count < 200 else { return nil }
        let hash = Self.hash(token)
        guard let index = devices.firstIndex(where: { Self.constantTimeEqual($0.tokenHash, hash) }) else { return nil }
        let now = Date()
        devices[index].lastSeenAt = now
        if now.timeIntervalSince(lastSeenWrites[devices[index].id] ?? .distantPast) > 60 {
            lastSeenWrites[devices[index].id] = now
            try? store.save(devices[index])
            emit(.devicesChanged)
        }
        return devices[index]
    }

    public func listDevices() -> [PairedDevice] { devices }

    /// Removes the device and its chat logs; its files stay until deleted in the app.
    public func revoke(_ id: String) throws {
        try store.deleteDevice(id)
        try store.deleteChatLogs(deviceID: id)
        devices.removeAll { $0.id == id }
        emit(.revoked(deviceID: id))
        emit(.devicesChanged)
    }

    public func update(_ id: String, _ change: @Sendable (inout PairedDevice) -> Void) throws {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var copy = devices[index]
        change(&copy)
        if let quota = copy.fileQuotaBytes, !(0...1_099_511_627_776).contains(quota) { throw ConfigurationError.invalid("Device quota must be 0–1 TiB") }
        if let jobs = copy.maxJobs, !(1...16).contains(jobs) { throw ConfigurationError.invalid("Job limit must be 1–16") }
        try store.save(copy)
        devices[index] = copy
        emit(.updated(copy))
        emit(.devicesChanged)
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

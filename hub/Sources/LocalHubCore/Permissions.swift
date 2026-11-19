import Foundation
import Vapor

/// A device asked for something it may not do yet; the Mac's owner decides.
public struct PermissionRequest: Sendable, Identifiable, Equatable {
    public let id: String
    public let deviceID: String
    public let deviceName: String
    public let app: String
    /// A capability (`image.create`) or `mcp:<server>`.
    public let scope: String
    public let createdAt: Date

    public var title: String {
        if scope.hasPrefix("mcp:") { return "use the \(scope.dropFirst(4)) tools" }
        return Capability(rawValue: scope)?.title.lowercased() ?? scope
    }
}

public enum PermissionEvent: Sendable {
    case requested(PermissionRequest)
    case resolved(id: String)
}

/// "Ask on first use": holds a request for a missing permission while the Mac's owner
/// answers, instead of failing it outright. A denial is remembered for ten minutes.
public actor PermissionBroker {
    private let authority: PairingAuthority
    private let store: HubStore
    private var pending: [String: (request: PermissionRequest, waiters: [CheckedContinuation<Bool, Never>])] = [:]
    private var denied: [String: Date] = [:]
    private var subscribers: [UUID: AsyncStream<PermissionEvent>.Continuation] = [:]
    var answerTimeout: TimeInterval = 60

    init(authority: PairingAuthority, store: HubStore) {
        self.authority = authority
        self.store = store
    }

    public func events() -> AsyncStream<PermissionEvent> {
        let (stream, continuation) = AsyncStream<PermissionEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        subscribers[id] = continuation
        for item in pending.values { continuation.yield(.requested(item.request)) }
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
    private func emit(_ event: PermissionEvent) { for continuation in subscribers.values { continuation.yield(event) } }

    public var open: [PermissionRequest] { pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt } }

    func configureForTesting(answerTimeout: TimeInterval) { self.answerTimeout = answerTimeout }

    /// `true` once allowed; `false` when denied, unanswered in time, or asking is turned off.
    public func ask(device: PairedDevice, scope: String) async -> Bool {
        // Only ask when someone can answer: the app subscribes; the headless CLI does not.
        guard (try? store.settings())?.askOnFirstUse ?? false, !subscribers.isEmpty else { return false }
        let key = "\(device.id)|\(scope)"
        if let until = denied[key], until > Date() { return false }
        let timeout = answerTimeout
        let request = pending[key]?.request ?? PermissionRequest(id: UUID().uuidString, deviceID: device.id, deviceName: device.name,
            app: device.app, scope: scope, createdAt: Date())
        let isNew = pending[key] == nil
        return await withCheckedContinuation { continuation in
            pending[key, default: (request, [])].waiters.append(continuation)
            if isNew {
                emit(.requested(request))
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    self.expire(key, id: request.id)
                }
            }
        }
    }

    public func answer(_ id: String, allow: Bool) async {
        guard let (key, item) = pending.first(where: { $0.value.request.id == id }) else { return }
        pending[key] = nil
        if allow {
            let scope = item.request.scope
            try? await authority.update(item.request.deviceID) { device in
                if !device.scopes.contains(scope) { device.scopes.append(scope) }
            }
        } else {
            denied[key] = Date().addingTimeInterval(600)
        }
        for waiter in item.waiters { waiter.resume(returning: allow) }
        emit(.resolved(id: id))
    }

    private func expire(_ key: String, id: String) {
        guard let item = pending[key], item.request.id == id else { return }
        pending[key] = nil
        for waiter in item.waiters { waiter.resume(returning: false) }
        emit(.resolved(id: id))
    }
}

struct PermissionsKey: StorageKey { typealias Value = PermissionBroker }

extension Request {
    /// The device's permission for `scope`, asking the Mac's owner when it is missing and asking is on.
    func require(scope: String) async throws {
        let device = try device
        if device.allows(scope) { return }
        if let broker = application.storage[PermissionsKey.self], await broker.ask(device: device, scope: scope) { return }
        let what = scope.hasPrefix("mcp:") ? "use the \(scope.dropFirst(4)) tools" : (Capability(rawValue: scope)?.title.lowercased() ?? scope)
        throw HubError(.forbidden, "forbidden", "This device may not \(what); allow it in LocalHub › Devices")
    }

    func require(_ capability: Capability) async throws {
        try await require(scope: capability.rawValue)
    }
}

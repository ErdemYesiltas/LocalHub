import Foundation
import Security

public struct HubSession: Codable, Sendable, Equatable {
    public var address: URL
    public var fingerprint: String
    public var token: String
    public var deviceID: String
    public var scopes: [String]
    public var hubID: String?
    public var hubName: String?

    public init(address: URL, fingerprint: String, token: String, deviceID: String, scopes: [String],
                hubID: String? = nil, hubName: String? = nil) {
        self.address = address; self.fingerprint = fingerprint; self.token = token; self.deviceID = deviceID
        self.scopes = scopes; self.hubID = hubID; self.hubName = hubName
    }
}

/// Where the session (and its bearer token) lives. Never preferences or a plain file.
public protocol SessionStore: Sendable {
    func load() async throws -> HubSession?
    func save(_ session: HubSession) async throws
    func clear() async throws
}

public actor MemorySessionStore: SessionStore {
    private var session: HubSession?
    public init() {}
    public func load() -> HubSession? { session }
    public func save(_ session: HubSession) { self.session = session }
    public func clear() { session = nil }
}

/// The Keychain (generic password), this device only.
public struct KeychainSessionStore: SessionStore {
    public let service: String
    public let account: String
    public init(service: String = "LocalHub", account: String = "session") { self.service = service; self.account = account }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() async throws -> HubSession? {
        var result: AnyObject?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { a, _ in a } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HubClientError.keychain(status) }
        return try JSONDecoder().decode(HubSession.self, from: data)
    }

    public func save(_ session: HubSession) async throws {
        let data = try JSONEncoder().encode(session)
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query.merging([kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { a, _ in a } as CFDictionary, nil)
        guard status == errSecSuccess else { throw HubClientError.keychain(status) }
    }

    public func clear() async throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HubClientError.keychain(status) }
    }
}

public enum HubClientError: Error, Equatable, LocalizedError {
    case invalidInvite(String)
    case notPaired
    case pinMismatch
    /// The hub's `{"error": {code, message, provider?}}`.
    case hub(status: Int, code: String, message: String, provider: String?)
    case keychain(OSStatus)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .invalidInvite(let message): message
        case .notPaired: "LocalHub is not paired"
        case .pinMismatch: "The hub certificate does not match the paired fingerprint"
        case .hub(_, _, let message, _): message
        case .keychain(let status): "Keychain error \(status)"
        case .badResponse: "Unexpected response from LocalHub"
        }
    }

    public var code: String? { if case .hub(_, let code, _, _) = self { return code }; return nil }
}

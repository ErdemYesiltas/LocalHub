import Foundation

/// What the hub's QR carries. Scanning grants no more trust than typing the same values;
/// the fingerprint is the only trust anchor.
public struct HubInvite: Sendable, Equatable {
    public let address: URL
    public let fingerprint: String
    public let code: String
    public let version: Int
    public let hubID: String?
    public let hubName: String?

    /// v2: `localhub://pair?v=2&u=…&fp=…&c=…&id=…&n=…`; v1: `artblend-companion://pair?v=1&u=…&fp=…&c=…`.
    public init(_ raw: String) throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 1024, let components = URLComponents(string: text),
              components.scheme == "localhub" || components.scheme == "artblend-companion",
              components.host == "pair", components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw HubClientError.invalidInvite("Not a LocalHub pairing code")
        }
        let items = components.queryItems ?? []
        func single(_ name: String, required: Bool = true) throws -> String? {
            let values = items.filter { $0.name == name }.compactMap(\.value)
            guard values.count <= 1, !required || values.count == 1 else { throw HubClientError.invalidInvite("Incomplete pairing code") }
            return values.first
        }
        let v = try single("v")
        let isV2 = components.scheme == "localhub" && v == "2"
        guard isV2 || (components.scheme == "artblend-companion" && v == "1") else {
            throw HubClientError.invalidInvite("Unsupported pairing code version")
        }
        let code = try single("c")!
        guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else { throw HubClientError.invalidInvite("Invalid pairing code in QR") }
        address = try hubAddress(try single("u")!)
        fingerprint = try normalizeFingerprint(try single("fp")!)
        self.code = code
        version = isV2 ? 2 : 1
        let id = isV2 ? try single("id", required: false) : nil
        hubID = id.flatMap { $0.range(of: #"^[a-z0-9-]{1,64}$"#, options: .regularExpression) != nil ? $0 : nil }
        hubName = isV2 ? try single("n", required: false).map { String($0.prefix(40)) } : nil
    }
}

public func normalizeFingerprint(_ value: String) throws -> String {
    let normalized = value.replacingOccurrences(of: ":", with: "").filter { !$0.isWhitespace }.lowercased()
    guard normalized.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
        throw HubClientError.invalidInvite("Expected a SHA-256 certificate fingerprint")
    }
    return normalized
}

public func hubAddress(_ value: String) throws -> URL {
    guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)), components.scheme == "https",
          let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil, components.path.isEmpty || components.path == "/" else {
        throw HubClientError.invalidInvite("Enter an HTTPS hub address without a path or credentials")
    }
    var clean = URLComponents()
    clean.scheme = "https"; clean.host = host; clean.port = components.port
    return clean.url!
}

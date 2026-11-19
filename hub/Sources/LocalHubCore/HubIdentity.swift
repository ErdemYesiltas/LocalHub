import CryptoKit
import Foundation
import Security

/// Stable per-Mac identity so a client can tell "the same hub on a new IP"
/// from "a different hub". Not a secret: trust still comes from the pin.
public struct HubIdentity: Codable, Sendable {
    public let id: String
    public var name: String

    public static func load(directory: URL) throws -> HubIdentity {
        let url = directory.appendingPathComponent("hub.json")
        if let data = try? Data(contentsOf: url) { return try JSONDecoder().decode(HubIdentity.self, from: data) }
        let identity = HubIdentity(id: UUID().uuidString.lowercased(),
            name: Host.current().localizedName ?? "Mac")
        try JSONEncoder().encode(identity).write(to: url, options: .atomic)
        return identity
    }
}

/// Self-signed TLS identity. Clients pin the SHA-256 of the DER certificate;
/// no CA, hostname or IP is trusted, so the LAN address may change freely.
public struct LocalCertificate: Sendable {
    public let certificate: URL
    public let privateKey: URL
    public let fingerprint: String

    public init(directory: URL) throws {
        certificate = directory.appendingPathComponent("server.pem")
        privateKey = directory.appendingPathComponent("server-key.pem")
        if !FileManager.default.fileExists(atPath: certificate.path) ||
            !FileManager.default.fileExists(atPath: privateKey.path) {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            command.arguments = ["req", "-x509", "-newkey", "rsa:2048",
                "-nodes", "-days", "825", "-subj", "/CN=LocalHub",
                "-keyout", privateKey.path, "-out", certificate.path]
            command.standardOutput = FileHandle.nullDevice
            command.standardError = FileHandle.nullDevice
            try command.run(); command.waitUntilExit()
            guard command.terminationStatus == 0 else { throw CertificateError.generationFailed }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKey.path)
        }
        let pem = try String(contentsOf: certificate, encoding: .utf8)
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("---") }.joined()
        guard let der = Data(base64Encoded: body),
              SecCertificateCreateWithData(nil, der as CFData) != nil else { throw CertificateError.invalid }
        fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CertificateError: Error { case generationFailed, invalid }

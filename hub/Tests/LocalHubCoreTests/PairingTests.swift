import CoreImage
import Foundation
import GRDB
import XCTest
@testable import LocalHubCore

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("localhub-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

final class PairingTests: XCTestCase {
    func testOnlyTokenHashIsStoredAndRevocationSurvivesRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authority = try PairingAuthority(store: HubStore.open(directory: directory))
        await authority.openWindow(code: "123456")
        let pairing = try await authority.pair(code: "123456", deviceName: "MatePad", app: "artblend",
            requestedScopes: nil, grantable: ["chat", "image.edit"])
        XCTAssertEqual(pairing.scopes, ["chat", "image.edit"])
        let device = await authority.device(for: pairing.token)
        XCTAssertEqual(device?.app, "artblend")
        XCTAssertNotNil(device?.lastSeenAt)
        let saved = try Data(contentsOf: directory.appendingPathComponent("hub.sqlite"))
        XCTAssertNil(saved.range(of: Data(pairing.token.utf8)))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("hub.sqlite").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let restarted = try PairingAuthority(store: HubStore.open(directory: directory))
        let restored = await restarted.device(for: pairing.token)
        XCTAssertEqual(restored?.id, pairing.deviceID)
        try await restarted.revoke(pairing.deviceID)
        let revoked = await restarted.device(for: pairing.token)
        XCTAssertNil(revoked)
    }

    func testWindowIsSingleUseAndClosedWindowNeverIssuesToken() async throws {
        let authority = try PairingAuthority(store: HubStore(path: nil))
        do { _ = try await authority.pair(code: "123456", deviceName: "Tablet", app: "a", requestedScopes: nil, grantable: [])
            XCTFail("Paired without a window") } catch PairingError.closed {}

        await authority.openWindow(code: "123456")
        do { _ = try await authority.pair(code: "000000", deviceName: "Tablet", app: "a", requestedScopes: nil, grantable: [])
            XCTFail("Accepted wrong code") } catch PairingError.denied {}
        _ = try await authority.pair(code: "123456", deviceName: "Tablet", app: "a", requestedScopes: nil, grantable: [])
        do { _ = try await authority.pair(code: "123456", deviceName: "Second", app: "a", requestedScopes: nil, grantable: [])
            XCTFail("Window reused") } catch PairingError.closed {}

        await authority.openWindow(code: "654321", lifetime: -1)
        do { _ = try await authority.pair(code: "654321", deviceName: "Tablet", app: "a", requestedScopes: nil, grantable: [])
            XCTFail("Accepted expired code") } catch PairingError.closed {}
        let nothing = await authority.device(for: nil)
        XCTAssertNil(nothing)
    }

    func testTenWrongCodesCloseTheWindow() async throws {
        let authority = try PairingAuthority(store: HubStore(path: nil))
        await authority.openWindow(code: "123456")
        for _ in 0..<10 { _ = try? await authority.pair(code: "000000", deviceName: "x", app: "a", requestedScopes: nil, grantable: []) }
        do { _ = try await authority.pair(code: "123456", deviceName: "x", app: "a", requestedScopes: nil, grantable: [])
            XCTFail("Brute force window stayed open") } catch PairingError.tooManyAttempts {}
    }

    func testRequestedScopesAreNarrowedToGrantable() async throws {
        let authority = try PairingAuthority(store: HubStore(path: nil))
        await authority.openWindow(code: "123456")
        let pairing = try await authority.pair(code: "123456", deviceName: "Olive", app: "olive-studio",
            requestedScopes: ["chat", "mcp:filesystem"], grantable: ["chat", "image.edit"])
        XCTAssertEqual(pairing.scopes, ["chat"])
    }
}

final class InviteTests: XCTestCase {
    func testV2InviteEncodesEveryValueAndScansBack() throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let uri = PairingInvite.uri(address: "https://192.168.1.20:8790", fingerprint: fingerprint, code: "012345",
            hubID: "4f1c", hubName: "Studio Mac & Co")
        XCTAssertEqual(uri, "localhub://pair?v=2&u=https%3A%2F%2F192.168.1.20%3A8790&fp=\(fingerprint)&c=012345&id=4f1c&n=Studio%20Mac%20%26%20Co")
        let items = try XCTUnwrap(URLComponents(string: uri)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "u" }?.value, "https://192.168.1.20:8790")
        XCTAssertEqual(items.first { $0.name == "n" }?.value, "Studio Mac & Co")
        XCTAssertEqual(try decodeQR(uri), uri)
    }

    func testLegacyInviteMatchesCompanionV1() {
        let fingerprint = String(repeating: "ab", count: 32)
        XCTAssertEqual(PairingInvite.legacyURI(address: "https://192.168.1.20:8765", fingerprint: fingerprint, code: "012345"),
            "artblend-companion://pair?v=1&u=https%3A%2F%2F192.168.1.20%3A8765&fp=\(fingerprint)&c=012345")
    }

    func testLocalNetworkFilter() {
        for ip in ["127.0.0.1", "10.1.2.3", "172.16.0.9", "192.168.1.20", "169.254.3.4", "::1", "fe80::1", "fd12::3", "::ffff:192.168.0.2"] {
            XCTAssertTrue(LocalNetwork.isLocal(ip), ip)
        }
        for ip in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "2001:db8::1", "::ffff:1.1.1.1", "garbage"] {
            XCTAssertFalse(LocalNetwork.isLocal(ip), ip)
        }
        for address in PairingInvite.lanAddresses() { XCTAssertTrue(LocalNetwork.isPrivateIPv4(address)) }
    }

    private func decodeQR(_ text: String) throws -> String? {
        let modules = try XCTUnwrap(PairingInvite.modules(for: text))
        XCTAssertTrue(modules.allSatisfy { $0.count == modules.count })
        XCTAssertEqual(PairingInvite.terminal(modules).split(separator: "\n").count, (modules.count + 4 + 1) / 2)
        let scale = 8, quiet = 4, size = (modules.count + quiet * 2) * scale
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for (y, row) in modules.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<scale { for dx in 0..<scale {
                    let i = (((y + quiet) * scale + dy) * size + (x + quiet) * scale + dx) * 4
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
                } }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: size * 4,
            size: CGSize(width: size, height: size), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

final class StoreTests: XCTestCase {
    func testPhase1ScopesMigrateToCapabilities() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hub.sqlite").path
        let old = try DatabaseQueue(path: path)
        try HubStore.migrator.migrate(old, upTo: "v1")
        try old.write { db in
            try db.execute(sql: "INSERT INTO device (id, name, app, tokenHash, createdAt, scopes) VALUES ('D', 'Pad', 'artblend', 'h', ?, ?)",
                arguments: [Date(), #"["lmstudio","comfyui","mcp:files","gone"]"#])
        }
        try old.close()
        XCTAssertEqual(try HubStore(path: path).devices().first?.scopes, ["chat", "image.create", "image.edit", "mcp:files"])
    }

    func testIntegrationsMustBeLoopback() throws {
        let store = try HubStore(path: nil)
        XCTAssertEqual(try store.integrations().map(\.id), ["lmstudio", "ollama", "comfyui"])
        for url in ["http://192.168.1.5:1234", "http://example.com", "file:///etc/passwd", "http://user:pw@127.0.0.1:1"] {
            XCTAssertThrowsError(try store.save(ProviderConfiguration(id: "x", kind: .openai, name: "X", baseURL: url)), url)
        }
        XCTAssertThrowsError(try store.save(ProviderConfiguration(id: "Bad ID", kind: .openai, name: "X", baseURL: "http://127.0.0.1:1")))
        try store.save(ProviderConfiguration(id: "mlx", kind: .openai, name: "MLX", baseURL: "http://127.0.0.1:8080"))
        try store.deleteIntegration("ollama")
        XCTAssertEqual(try store.integrations().map(\.id), ["lmstudio", "comfyui", "mlx"])
    }

    func testSettingsRoundTripAndKeepDefaultsForMissingKeys() throws {
        let store = try HubStore(path: nil)
        XCTAssertEqual(try store.settings(), HubSettings())
        var settings = HubSettings()
        settings.lanEnabled = true
        settings.retentionDays = 7
        try store.save(settings)
        XCTAssertEqual(try store.settings(), settings)
        settings.port = 80
        XCTAssertThrowsError(try store.save(settings))
        let partial = try JSONDecoder().decode(HubSettings.self, from: Data(#"{"port": 9000}"#.utf8))
        XCTAssertEqual(partial.port, 9000)
        XCTAssertEqual(partial.retentionDays, 30)
        XCTAssertTrue(partial.legacyV1)
    }

    func testCLIEraDevicesAreImportedOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = #"[{"id":"D1","name":"MatePad","app":"artblend","tokenHash":"\#(String(repeating: "a", count: 64))","createdAt":700000000,"scopes":["lmstudio"]}]"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("paired-devices.json"))
        let store = try HubStore.open(directory: directory)
        XCTAssertEqual(try store.devices().map(\.name), ["MatePad"])
        XCTAssertEqual(try store.devices().first?.scopes, ["chat"], "integration scopes become capabilities")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("paired-devices.json.migrated").path))
        XCTAssertEqual(try HubStore.open(directory: directory).devices().count, 1)
    }
}

final class OpenAPITests: XCTestCase {
    func testServedSpecMatchesSourceAndCoversEveryRoute() throws {
        let specURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../api/openapi.yaml").standardized
        let source = try String(contentsOf: specURL, encoding: .utf8)
        XCTAssertEqual(openAPISpec, source, "run scripts/sync-openapi.sh after editing api/openapi.yaml")
        for path in ["/v1/chat/completions", "/v1/embeddings", "/v1/images/edits", "/v1/audio/transcriptions", "/v1/videos/{id}/remix",
                     "/v1/3d/generations", "/v1/jobs/{id}/preview", "/v2/events", "/v2/pair", "/v2/mcp/{server}/call"] {
            XCTAssertTrue(openAPISpec.contains("\n  \(path):"), path)
        }
    }
}

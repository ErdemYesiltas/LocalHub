import Foundation
import XCTest
@testable import LocalHubCore

/// "Ask on first use": a missing permission is held while the Mac's owner answers.
final class PermissionTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    private var core: HubCore!
    private var server: HubServer!
    private var hubURL: URL!
    private var client: PinnedClient!

    override func setUp() async throws {
        directory = try temporaryDirectory()
        core = try HubCore(directory: directory)
        var settings = HubSettings()
        settings.defaultScopes = ["chat"]
        try core.store.save(settings)
        server = HubServer(core: core)
        try await server.start(settings: settings, portOverride: 0)
        let port = await server.port
        hubURL = URL(string: "https://127.0.0.1:\(try XCTUnwrap(port))")!
        client = PinnedClient(fingerprint: core.certificate.fingerprint)
    }

    override func tearDown() async throws {
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func pair(_ name: String) async throws -> String {
        let window = await core.authority.openWindow()
        let (result, _) = try await client.json("POST", hubURL.appendingPathComponent("v2/pair"), token: nil,
            body: ["code": window.code, "deviceName": name, "app": "tests"])
        return try XCTUnwrap(result["token"] as? String)
    }

    private func generate(_ token: String) async throws -> (String?, Int) {
        let (body, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/images/generations"), token: token,
            body: ["prompt": "a fox"])
        return ((body["error"] as? [String: Any])?["code"] as? String, status)
    }

    func testAllowedRequestContinuesAndTheDeviceKeepsThePermission() async throws {
        let token = try await pair("MatePad")
        var events = await core.permissions.events().makeAsyncIterator()
        let request = Task { try await self.generate(token) }
        guard case .requested(let asked)? = await events.next() else { return XCTFail("No permission request") }
        XCTAssertEqual(asked.scope, "image.create")
        XCTAssertEqual(asked.deviceName, "MatePad")
        XCTAssertEqual(asked.title, "create images")
        await core.permissions.answer(asked.id, allow: true)
        let (code, status) = try await request.value
        XCTAssertEqual(status, 404, "past the permission check; this Mac simply has no image workflow")
        XCTAssertEqual(code, "capability_unavailable")
        let devices = await core.authority.listDevices()
        XCTAssertTrue(devices[0].allows("image.create"), "the answer is remembered as a permission")
    }

    func testDenialIsRememberedAndUnansweredRequestsTimeOut() async throws {
        let token = try await pair("Laptop")
        var events = await core.permissions.events().makeAsyncIterator()
        let first = Task { try await self.generate(token) }
        guard case .requested(let asked)? = await events.next() else { return XCTFail("No permission request") }
        await core.permissions.answer(asked.id, allow: false)
        let (code, status) = try await first.value
        XCTAssertEqual(status, 403)
        XCTAssertEqual(code, "forbidden")
        let started = Date()
        let (_, again) = try await generate(token)
        XCTAssertEqual(again, 403)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a recent denial is not asked again")

        await core.permissions.configureForTesting(answerTimeout: 0.3)
        let other = try await pair("Phone")
        let (_, unanswered) = try await generate(other)
        XCTAssertEqual(unanswered, 403, "nobody answered in time")
    }

    func testWithoutTheAppNobodyIsAskedAndVPNAddressesAreRecognised() async throws {
        let token = try await pair("Headless")
        let started = Date()
        let (_, status) = try await generate(token)
        XCTAssertEqual(status, 403)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "no app listening, so no waiting")

        XCTAssertTrue(LocalNetwork.isVPN("100.101.102.103"))
        XCTAssertTrue(LocalNetwork.isVPN("::ffff:100.64.0.1"))
        XCTAssertFalse(LocalNetwork.isVPN("100.128.0.1"))
        XCTAssertFalse(LocalNetwork.isLocal("100.101.102.103"), "VPN addresses need the setting")
    }
}

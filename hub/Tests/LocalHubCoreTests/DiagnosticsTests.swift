import Foundation
import XCTest
@testable import LocalHubCore

final class DiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testStoppedHubMissingPermissionAndUnavailableProviderAreReported() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try HubCore(directory: directory), server = HubServer(core: core)
        for integration in core.integrations.list { try core.integrations.delete(integration.id) }
        try core.integrations.save(ProviderConfiguration(id: "private-app", kind: .openai, name: "Secret Project Server", baseURL: "http://127.0.0.1:1"))
        let (_, id) = try await core.authority.issue(name: "Private Tablet", app: "tests", scopes: [Capability.chat.rawValue])
        let report = await HubDiagnostics.run(core: core, server: server, deviceID: id, capability: .imageCreate)
        XCTAssertTrue(report.checks.contains { $0.code == "hub.stopped" && $0.finding.status == .failed })
        XCTAssertTrue(report.checks.contains { $0.code == "device.permission_missing" && $0.action == .devices })
        XCTAssertTrue(report.checks.contains { $0.code == "integration.unavailable" })
        XCTAssertTrue(report.checks.contains { $0.code == "capability.provider_unavailable" })
        XCTAssertTrue(report.checks.contains { $0.code == "certificate.valid" })
        XCTAssertFalse(report.supportText.contains("Secret Project"))
        XCTAssertFalse(report.supportText.contains("Private Tablet"))
        XCTAssertFalse(report.supportText.contains("127.0.0.1"))
        XCTAssertFalse(report.supportText.contains(id))
        XCTAssertFalse(report.supportText.contains(core.certificate.fingerprint))
    }

    func testSupportSummaryNeverCopiesRawTitlesOrDetails() {
        let check = DiagnosticCheck("private-device-id", "Private user name", .failed,
            "token=secret-token; prompt=private-prompt; /Users/private/path; https://192.168.1.2", code: "device.permission_missing", action: .devices)
        let report = DiagnosticReport(checkedAt: Date(timeIntervalSince1970: 1), checks: [check])
        XCTAssertTrue(report.supportText.contains("device.permission_missing"))
        for secret in ["private-device-id", "Private user name", "secret-token", "private-prompt", "/Users/", "192.168."] {
            XCTAssertFalse(report.supportText.contains(secret))
        }
    }

    func testRemovedDeviceAndNoIntegrationsAreReported() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try HubCore(directory: directory), server = HubServer(core: core)
        for integration in core.integrations.list { try core.integrations.delete(integration.id) }
        let report = await HubDiagnostics.run(core: core, server: server, deviceID: "removed")
        XCTAssertTrue(report.checks.contains { $0.code == "device.not_paired" })
        XCTAssertTrue(report.checks.contains { $0.code == "integration.none" })
        XCTAssertTrue(report.checks.contains { $0.code == "network.remote_route_not_tested" && $0.finding.status == .info })
    }
}

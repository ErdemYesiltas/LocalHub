import Foundation
import LocalHubCore
import Vapor
import XCTest
@testable import LocalHubApp

final class HubControllerTests: XCTestCase, @unchecked Sendable {
    @MainActor
    private func fixture(modelIDs: [String] = ["qwen", "embed-small"]) async throws -> (HubController, Application, URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("localhub-app-test-\(UUID().uuidString)")
        let suite = "localhub-app-test-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let provider = try await Application.make(.testing)
        provider.get("v1", "models") { _ async throws -> Response in
            try await Task.sleep(for: .milliseconds(30))
            let data = try JSONSerialization.data(withJSONObject: ["data": modelIDs.map { ["id": $0] }])
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: data))
        }
        provider.get("system_stats") { _ -> Response in
            Response(status: .ok, body: .init(string: #"{"system":{"ram_free":8589934592},"devices":[{"type":"mps"}]}"#))
        }
        provider.post("prompt") { _ in ["prompt_id": UUID().uuidString] }
        provider.get("history", ":id") { request -> Response in
            let id = request.parameters.get("id")!
            return Response(status: .ok, body: .init(string: #"{"\#(id)":{"status":{"status_str":"success","completed":true},"outputs":{"9":{"images":[{"filename":"out.png","subfolder":"","type":"output"}]}}}}"#))
        }
        provider.get("view") { _ in
            Response(status: .ok, headers: ["Content-Type": "image/png"], body: .init(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!))
        }
        try await provider.server.start(address: .hostname("127.0.0.1", port: 0))
        let port = try XCTUnwrap(provider.http.server.shared.localAddress?.port)
        let core = try HubCore(directory: directory)
        for integration in core.integrations.list { try core.integrations.delete(integration.id) }
        try core.integrations.save(ProviderConfiguration(id: "models", kind: .openai, name: "Models", baseURL: "http://127.0.0.1:\(port)"))
        try core.integrations.save(ProviderConfiguration(id: "comfy", kind: .comfyui, name: "ComfyUI", baseURL: "http://127.0.0.1:\(port)"))
        return (HubController(core: core, preferences: preferences), provider, directory, suite)
    }

    @MainActor
    private func cleanUp(_ hub: HubController, _ provider: Application, _ directory: URL, _ suite: String) async throws {
        await hub.stop()
        await provider.server.shutdown()
        try await provider.asyncShutdown()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testReadinessRequiresAUsableModelOrWorkflowAndARunningHub() async throws {
        let (hub, provider, directory, suite) = try await fixture()
        do {
            XCTAssertTrue(hub.readyCapabilities.isEmpty)
            await hub.start(portOverride: 0)
            XCTAssertTrue(hub.isRunning)
            XCTAssertNil(hub.modelError)
            XCTAssertEqual(Set(hub.readyCapabilities), [.chat, .embeddings])
            let comfy = try XCTUnwrap(hub.integrations.first { $0.id == "comfy" })
            XCTAssertTrue(hub.capabilities(for: comfy).isEmpty, "Reachable ComfyUI without a workflow cannot generate images")

            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../examples/workflows/sdxl-text-to-image.json").standardized
            let json = try String(contentsOf: url, encoding: .utf8)
            let slots = try WorkflowGraph(json: json).detectSlots()
            XCTAssertNil(hub.save(WorkflowTemplate(id: "sdxl", name: "SDXL", integrationID: "comfy", capability: slots.capability,
                workflow: json, slots: slots.slots, outputNode: slots.outputNode)))
            XCTAssertTrue(hub.readyCapabilities.contains(.imageCreate))
            await hub.stop()
            XCTAssertTrue(hub.playgroundModels.isEmpty)
            XCTAssertTrue(hub.readyCapabilities.isEmpty)
        } catch {
            try await cleanUp(hub, provider, directory, suite)
            throw error
        }
        try await cleanUp(hub, provider, directory, suite)
    }

    @MainActor
    func testReachableModelServerWithEmptyCatalogIsNotReady() async throws {
        let (hub, provider, directory, suite) = try await fixture(modelIDs: [])
        await hub.start(portOverride: 0)
        XCTAssertEqual(hub.statuses["models"]?.state, "running")
        XCTAssertTrue(hub.playgroundModels.isEmpty)
        XCTAssertTrue(hub.readyCapabilities.isEmpty)
        try await cleanUp(hub, provider, directory, suite)
    }

    @MainActor
    func testConcurrentRefreshKeepsThePlaygroundSessionValid() async throws {
        let (hub, provider, directory, suite) = try await fixture()
        let starting = Task { await hub.start(portOverride: 0) }
        for _ in 0..<200 {
            if hub.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard hub.isRunning else {
            await starting.value
            try await cleanUp(hub, provider, directory, suite)
            XCTFail("The test hub did not start")
            return
        }
        async let connectionA = hub.playgroundClient()
        async let connectionB = hub.playgroundClient()
        let clients = try await (connectionA, connectionB)
        XCTAssertTrue(clients.0 === clients.1)
        await starting.value
        async let first: Void = hub.refreshModels()
        async let second: Void = hub.refreshModels()
        _ = await (first, second)
        XCTAssertFalse(hub.loadingModels)
        XCTAssertNil(hub.modelError)
        XCTAssertEqual(hub.playgroundModels.count, 2)
        let devices = await hub.core.authority.listDevices().filter { $0.app == PairingAuthority.playgroundApp }
        XCTAssertEqual(devices.count, 1)
        try await cleanUp(hub, provider, directory, suite)
    }

    @MainActor
    func testSetupDismissalAndFirstSuccessPersistIndependentlyPerHub() async throws {
        let (hub, provider, directory, suite) = try await fixture()
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(hub.setupDismissed)
        XCTAssertFalse(hub.hasCompletedPlaygroundRun)
        hub.dismissSetup()
        let reopened = HubController(core: hub.core, preferences: preferences)
        XCTAssertTrue(reopened.setupDismissed)
        XCTAssertFalse(reopened.hasCompletedPlaygroundRun, "Opening or dismissing setup is not a successful request")
        hub.completePlaygroundRun()
        let afterSuccess = HubController(core: hub.core, preferences: preferences)
        XCTAssertTrue(afterSuccess.hasCompletedPlaygroundRun)
        let otherDirectory = directory.appendingPathComponent("another-hub")
        let other = HubController(core: try HubCore(directory: otherDirectory), preferences: preferences)
        XCTAssertFalse(other.setupDismissed)
        XCTAssertFalse(other.hasCompletedPlaygroundRun)
        try await cleanUp(hub, provider, directory, suite)
    }

    @MainActor
    func testWorkflowTestAndLocalReplayUseTheJobPipelineAndArchivedRecipe() async throws {
        let (hub, provider, directory, suite) = try await fixture()
        do {
            await hub.start(portOverride: 0)
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../examples/workflows/sdxl-text-to-image.json").standardized
            let json = try String(contentsOf: url, encoding: .utf8), detected = try WorkflowGraph(json: json).detectSlots()
            let template = WorkflowTemplate(id: "draft", name: "Unsaved draft", integrationID: "comfy", capability: .imageCreate,
                workflow: json, slots: detected.slots, outputNode: detected.outputNode)
            let test = try await hub.testWorkflow(template, prompt: "a test cube", input: nil)
            XCTAssertEqual(hub.selectedJobID, test.id)
            XCTAssertEqual(test.recipe?.parameters.seed, 42)
            XCTAssertEqual(test.recipe?.parameters.steps, 4)
            XCTAssertEqual(test.recipe?.parameters.width, 512)
            let complete = await hub.core.jobs.wait(test.id)
            XCTAssertEqual(complete?.status, .completed, complete?.error ?? "No job returned")
            let replay = try await hub.replay(try XCTUnwrap(complete), variation: true)
            XCTAssertEqual(hub.selectedJobID, replay.id)
            XCTAssertEqual(replay.recipe?.template.name, "Unsaved draft")
            XCTAssertNotEqual(replay.recipe?.parameters.seed, test.recipe?.parameters.seed)
            let replayComplete = await hub.core.jobs.wait(replay.id)
            XCTAssertEqual(replayComplete?.status, .completed, replayComplete?.error ?? "No replay returned")
        } catch {
            try await cleanUp(hub, provider, directory, suite)
            throw error
        }
        try await cleanUp(hub, provider, directory, suite)
    }

    @MainActor
    func testProfilesApplyLimitsAndRemovalClearsDefaultsWithoutChangingOtherDevices() async throws {
        let (hub, provider, directory, suite) = try await fixture()
        do {
            let window = await hub.core.authority.openWindow()
            let paired = try await hub.core.authority.pair(code: window.code, deviceName: "Pad", app: "tests",
                requestedScopes: nil, grantable: Capability.allCases.map(\.rawValue))
            await hub.refreshDevices()
            let device = try XCTUnwrap(hub.devices.first { $0.id == paired.deviceID })
            await hub.applyProfile("guest", to: device)
            XCTAssertEqual(hub.devices.first?.profileID, "guest")
            XCTAssertFalse(hub.devices.first?.logging ?? true)
            await hub.setDeviceLimits(try XCTUnwrap(hub.devices.first), quotaMiB: 128, maxJobs: 2)
            XCTAssertNil(hub.devices.first?.profileID)
            XCTAssertEqual(hub.devices.first?.fileQuotaBytes, 128 * 1_048_576)
            let work = WorkProfile(id: "custom", name: "Custom", steps: 6)
            try hub.saveProfile(work, isNew: true)
            XCTAssertThrowsError(try hub.saveProfile(work, isNew: true))
            await hub.setWorkProfile(work.id, for: try XCTUnwrap(hub.devices.first))
            XCTAssertEqual(hub.devices.first?.workProfileID, work.id)
            try await hub.deleteProfile(work)
            XCTAssertNil(hub.devices.first?.workProfileID)
            XCTAssertFalse(hub.settings.workProfiles.contains { $0.id == work.id })
            let policy = DeviceProfile(id: "custom", name: "Custom", scopes: ["chat"], logging: false, fileQuotaBytes: 1_048_576, maxJobs: 1)
            try hub.saveProfile(policy, isNew: true)
            var next = hub.settings; next.defaultDeviceProfileID = policy.id; await hub.apply(next)
            try hub.deleteProfile(policy)
            XCTAssertNil(hub.settings.defaultDeviceProfileID)
            XCTAssertEqual(hub.devices.first?.fileQuotaBytes, 128 * 1_048_576)
        } catch { try await cleanUp(hub, provider, directory, suite); throw error }
        try await cleanUp(hub, provider, directory, suite)
    }
}

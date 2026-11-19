import Foundation
import GRDB
import LocalHubClient
import Vapor
import XCTest
@testable import LocalHubCore

final class ProfileTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    private var core: HubCore!
    private var provider: Application!
    private var server: HubServer!
    private var fake: FakeComfy!
    private var sdk: LocalHubClient.HubClient!
    private var deviceID = ""
    private var address: URL!

    override func setUp() async throws {
        directory = try temporaryDirectory(); provider = try await Application.make(.testing)
        fake = FakeComfy(); fake.routes(provider)
        provider.get("v1", "models") { _ in Response(status: .ok, body: .init(string: #"{"data":[{"id":"qwen"}]}"#)) }
        provider.post("v1", "chat", "completions") { request -> Response in
            let json = try JSONSerialization.jsonObject(with: Data(request.body.data!.readableBytesView)) as! [String: Any]
            let text = json["profile"] == nil && json["model"] as? String == "qwen" ? "profile stripped" : "bad forwarding"
            return Response(status: .ok, body: .init(string: "{\"choices\":[{\"message\":{\"content\":\"\(text)\"}}]}"))
        }
        try await provider.server.start(address: .hostname("127.0.0.1", port: 0))
        let port = try XCTUnwrap(provider.http.server.shared.localAddress?.port)
        core = try HubCore(directory: directory)
        for integration in core.integrations.list { try core.integrations.delete(integration.id) }
        try core.integrations.save(ProviderConfiguration(id: "comfy", kind: .comfyui, name: "Comfy", baseURL: "http://127.0.0.1:\(port)"))
        try core.integrations.save(ProviderConfiguration(id: "ai", kind: .openai, name: "AI", baseURL: "http://127.0.0.1:\(port)"))
        for (id, name) in [("create", "sdxl-text-to-image.json"), ("edit", "sdxl-inpaint.json")] {
            let json = try sample(name), slots = try WorkflowGraph(json: json).detectSlots()
            try core.integrations.save(WorkflowTemplate(id: id, name: id, integrationID: "comfy", capability: slots.capability, workflow: json, slots: slots.slots, outputNode: slots.outputNode))
        }
        var settings = HubSettings(); settings.minFreeMemoryGB = 0
        settings.defaults["image.create"] = "comfy/create"; settings.defaults["image.edit"] = "comfy/edit"
        settings.workProfiles.append(WorkProfile(id: "studio", name: "Studio", models: ["chat": "ai/qwen", "image.create": "comfy/create"], steps: 9, width: 768, height: 768))
        try core.store.save(settings)
        server = HubServer(core: core); try await server.start(settings: settings, portOverride: 0)
        let bound = await server.port; address = URL(string: "https://127.0.0.1:\(try XCTUnwrap(bound))")!
        sdk = try await pair()
        let session = await sdk.session
        deviceID = try XCTUnwrap(session?.deviceID)
    }

    private func pair(scopes: [String]? = nil) async throws -> LocalHubClient.HubClient {
        let client = LocalHubClient.HubClient(store: LocalHubClient.MemorySessionStore())
        let window = await core.authority.openWindow()
        let invite = try LocalHubClient.HubInvite(core.invite(address: address.absoluteString, window: window))
        _ = try await client.pair(invite, deviceName: "Test Pad", app: "tests", scopes: scopes)
        return client
    }

    override func tearDown() async throws {
        for job in await core.jobs.list(deviceID: nil) where !job.status.isFinished { await core.jobs.cancel(job.id, deviceID: nil); _ = await core.jobs.wait(job.id) }
        await server.stop(); await provider.server.shutdown(); try await provider.asyncShutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func testPairingProfileCopiesPolicyIntersectsScopesAndPersists() async throws {
        var settings = try core.store.settings(); settings.defaultDeviceProfileID = "guest"; try core.store.save(settings)
        let guest = try await pair(scopes: ["chat", "image.edit", "mcp:files"])
        let currentSession = await guest.session
        let session = try XCTUnwrap(currentSession)
        XCTAssertEqual(session.scopes, ["chat"])
        let policy = try XCTUnwrap(try core.store.devices().first { $0.id == session.deviceID })
        XCTAssertEqual(policy.profileID, "guest"); XCTAssertEqual(policy.maxJobs, 1)
        XCTAssertFalse(policy.logging); XCTAssertEqual(policy.fileQuotaBytes, 64 * 1024 * 1024)
        settings.deviceProfiles[2].fileQuotaBytes = 1; try core.store.save(settings)
        let restored = try PairingAuthority(store: HubStore.open(directory: directory))
        let devices = await restored.listDevices()
        XCTAssertEqual(devices.first { $0.id == session.deviceID }?.fileQuotaBytes, 64 * 1024 * 1024, "Profile edits must not silently alter copied device policy")
    }

    func testWorkProfileDefaultsExplicitOverridesAndRecipeSnapshot() async throws {
        let job = try await sdk.startImage(prompt: "a fox", profile: "studio")
        let result = await core.jobs.wait(job.id)
        let complete = try XCTUnwrap(result)
        XCTAssertEqual(complete.status, .completed)
        XCTAssertEqual(complete.recipe?.parameters.steps, 9); XCTAssertEqual(complete.recipe?.parameters.width, 768)
        XCTAssertEqual(complete.recipe?.workProfileID, "studio")
        _ = try await sdk.generateImage(prompt: "a boat", size: "512x512", extra: ["steps": 3], profile: "studio")
        let last = try XCTUnwrap(fake.prompts.last)
        XCTAssertEqual(((last["3"] as? [String: Any])?["inputs"] as? [String: Any])?["steps"] as? Int, 3)
        XCTAssertEqual(((last["5"] as? [String: Any])?["inputs"] as? [String: Any])?["width"] as? Int, 512)
    }

    func testDeviceDefaultWorkProfileAndExplicitNone() async throws {
        try await core.authority.update(deviceID) { $0.workProfileID = "draft" }
        let first = try await sdk.startImage(prompt: "draft")
        let draft = await core.jobs.wait(first.id)
        XCTAssertEqual(draft?.recipe?.parameters.steps, 4)
        let next = try await sdk.startImage(prompt: "original", profile: "")
        let original = await core.jobs.wait(next.id)
        XCTAssertEqual(original?.recipe?.parameters.steps, 25)
        XCTAssertNil(original?.recipe?.workProfileID)
    }

    func testProfileModelOnlyChatAndDiscoveryFiltering() async throws {
        let response = try await sdk.chat(ChatRequest(messages: [.user("hello")], profile: "studio"))
        XCTAssertEqual(response, "profile stripped")
        try await core.authority.update(deviceID) { $0.scopes = ["chat"] }
        let profiles = try await sdk.workProfiles()
        XCTAssertEqual(profiles.first { $0.id == "studio" }?.models, ["chat": "ai/qwen"])
        do { _ = try await sdk.startImage(prompt: "a fox", profile: "studio"); XCTFail("Profile must not bypass capability permissions") }
        catch let error as LocalHubClient.HubClientError { XCTAssertEqual(error.code, "forbidden") }
    }

    func testDeviceQuotaIsEnforcedForUploadsInputsAndOutputs() async throws {
        let quota = tinyPNG.count - 1
        try await core.authority.update(deviceID) { $0.fileQuotaBytes = quota }
        do { _ = try await sdk.uploadFile(tinyPNG, filename: "ref.png", contentType: "image/png"); XCTFail("Upload quota") }
        catch let error as LocalHubClient.HubClientError { XCTAssertEqual(error.code, "quota_exceeded") }
        do { _ = try await sdk.editImage(prompt: "forest", image: .data(tinyPNG, filename: "ref.png", contentType: "image/png")); XCTFail("Retained input quota") }
        catch let error as LocalHubClient.HubClientError { XCTAssertEqual(error.code, "quota_exceeded") }
        do { _ = try await sdk.generateImage(prompt: "fox"); XCTFail("Output quota") }
        catch let error as LocalHubClient.HubClientError { XCTAssertEqual(error.code, "quota_exceeded") }
        XCTAssertTrue(try core.files.list(deviceID: deviceID).isEmpty)
    }

    func testPerDeviceJobLimitOverridesTheHubDefault() async throws {
        fake.slow = true
        try await core.authority.update(deviceID) { $0.maxJobs = 1 }
        let job = try await sdk.startImage(prompt: "one")
        let second = try await sdk.startImage(prompt: "two")
        let waiting = await core.jobs.job(second.id, deviceID: deviceID)
        XCTAssertEqual(waiting?.status, .queued)
        XCTAssertNil(waiting?.dispatchedAt)
        XCTAssertEqual(waiting?.waitingReason, "Waiting for this device's running jobs")
        await core.jobs.cancel(second.id, deviceID: deviceID)
        await core.jobs.cancel(job.id, deviceID: deviceID); _ = await core.jobs.wait(job.id)
    }

    func testConcurrentFileCreationCannotOverspendQuota() async throws {
        let files = core.files, owner = deviceID, bytes = Data(repeating: 42, count: 1024)
        let succeeded = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<16 {
                group.addTask {
                    do { _ = try files.create(deviceID: owner, filename: "\(index).txt", mime: "text/plain", data: bytes, purpose: "test", source: "upload", quota: 4096); return true }
                    catch { return false }
                }
            }
            var count = 0; for await result in group { if result { count += 1 } }; return count
        }
        XCTAssertEqual(succeeded, 4); XCTAssertEqual(try files.usage(deviceID: owner), 4096)
    }
}

final class ProfileValidationTests: XCTestCase {
    func testProfilesRejectInvalidLimitsAndSettingsKeepBackwardDefaults() throws {
        let old = try JSONDecoder().decode(HubSettings.self, from: Data(#"{"port":8790}"#.utf8))
        XCTAssertEqual(old.deviceProfiles.count, 3); XCTAssertEqual(old.workProfiles.count, 3)
        XCTAssertFalse(DeviceProfile.presets.flatMap(\.scopes).contains { $0.hasPrefix("mcp:") })
        var bad = DeviceProfile.presets[0]; bad.maxJobs = 0; XCTAssertThrowsError(try bad.validate())
        var work = WorkProfile(id: "bad", name: "Bad", width: 513, height: 512); XCTAssertThrowsError(try work.validate())
        work.width = 512; work.seconds = .nan; XCTAssertThrowsError(try work.validate())
        var settings = old; settings.defaultDeviceProfileID = "missing"; XCTAssertThrowsError(try settings.validate())
        settings.defaultDeviceProfileID = nil; settings.workProfiles.append(settings.workProfiles[0]); XCTAssertThrowsError(try settings.validate())
    }

    func testPreProfileDatabaseKeepsDevicePermissionsAndUsesFallbackLimits() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hub.sqlite").path, old = try DatabaseQueue(path: directory.appendingPathComponent("hub.sqlite").path)
        try HubStore.migrator.migrate(old, upTo: "v6-job-recipes")
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO device (id, name, app, tokenHash, createdAt, scopes, logging)
                VALUES ('old-device', 'Old Pad', 'tests', 'hash', '2026-11-18 12:00:00.000', '["chat"]', 0)
                """)
        }
        let store = try HubStore(path: path), device = try XCTUnwrap(store.devices().first)
        XCTAssertEqual(device.scopes, ["chat"]); XCTAssertFalse(device.logging)
        XCTAssertNil(device.profileID); XCTAssertNil(device.fileQuotaBytes); XCTAssertNil(device.workProfileID)
        XCTAssertEqual(device.effectiveFileQuota(HubSettings()), HubSettings().fileQuotaBytes)
    }
}

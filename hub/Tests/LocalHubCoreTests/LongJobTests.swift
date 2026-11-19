import Foundation
import Vapor
import XCTest
@testable import LocalHubCore

/// Queue position, node progress, previews, ETA, template timeouts, re-attaching after a restart,
/// the memory guard and the per-device event stream, against the fake ComfyUI.
final class LongJobTests: XCTestCase, @unchecked Sendable {
    private var comfy: Application!
    private var fake: FakeComfy!
    private var server: HubServer!
    private var core: HubCore!
    private var directory: URL!
    private var hubURL: URL!
    private var client: PinnedClient!
    private var comfyPort = 0

    override func setUp() async throws {
        directory = try temporaryDirectory()
        fake = FakeComfy()
        comfy = try await Application.make(.testing)
        fake.routes(comfy)
        try await comfy.server.start(address: .hostname("127.0.0.1", port: 0))
        comfyPort = try XCTUnwrap(comfy.http.server.shared.localAddress?.port)
        core = try await makeCore()
        server = HubServer(core: core)
        var settings = HubSettings()
        settings.minFreeMemoryGB = 0
        try core.store.save(settings)
        try await server.start(settings: settings, portOverride: 0)
        let port = await server.port
        hubURL = URL(string: "https://127.0.0.1:\(try XCTUnwrap(port))")!
        client = PinnedClient(fingerprint: core.certificate.fingerprint)
    }

    private func makeCore() async throws -> HubCore {
        let core = try HubCore(directory: directory)
        if core.integrations.templates.isEmpty {
            try core.integrations.save(ProviderConfiguration(id: "comfyui", kind: .comfyui, name: "ComfyUI", baseURL: "http://127.0.0.1:\(comfyPort)"))
            let json = try sample("sdxl-text-to-image.json")
            let detected = try WorkflowGraph(json: json).detectSlots()
            try core.integrations.save(WorkflowTemplate(id: "sdxl", name: "SDXL", integrationID: "comfyui", capability: .imageCreate,
                workflow: json, slots: detected.slots, outputNode: detected.outputNode, timeoutMinutes: 1))
        }
        await core.jobs.configureForTesting(memoryPollInterval: 0.05)
        return core
    }

    override func tearDown() async throws {
        await server.stop()
        await comfy.server.shutdown(); try await comfy.asyncShutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func pair() async throws -> String {
        let window = await core.authority.openWindow()
        let (result, _) = try await client.json("POST", hubURL.appendingPathComponent("v2/pair"), token: nil,
            body: ["code": window.code, "deviceName": "Pad", "app": "tests"])
        return try XCTUnwrap(result["token"] as? String)
    }

    private func startJob(_ token: String) async throws -> String {
        let (job, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/images/generations"), token: token,
            body: ["prompt": "a lighthouse"], headers: ["Prefer": "respond-async"])
        XCTAssertEqual(status, 202, "\(job)")
        return try XCTUnwrap(job["id"] as? String)
    }

    private func poll(_ id: String, _ token: String, until done: ([String: Any]) -> Bool) async throws -> [String: Any] {
        var job: [String: Any] = [:]
        for _ in 0..<60 {
            job = try await client.json("GET", hubURL.appendingPathComponent("v1/jobs/\(id)"), token: token).0
            if done(job) { return job }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting; last state \(job)")
        return job
    }

    func testQueuePositionNodeProgressPreviewAndCompletion() async throws {
        fake.slow = true
        fake.ahead = 2
        let token = try await pair()
        let id = try await startJob(token)
        let queued = try await poll(id, token) { $0["queue_position"] as? Int != nil }
        XCTAssertEqual(queued["status"] as? String, "queued")
        XCTAssertEqual(queued["queue_position"] as? Int, 2, "one running and one pending before ours")

        fake.ahead = 0
        let promptID = try XCTUnwrap(fake.promptIDs.last)
        fake.send(id, text: #"{"type": "execution_start", "data": {"prompt_id": "\#(promptID)"}}"#)
        fake.send(id, text: #"{"type": "execution_cached", "data": {"prompt_id": "\#(promptID)", "nodes": ["4", "5", "6", "7"]}}"#)
        fake.send(id, text: #"{"type": "executing", "data": {"prompt_id": "\#(promptID)", "node": "3"}}"#)
        fake.send(id, text: #"{"type": "progress", "data": {"prompt_id": "\#(promptID)", "node": "3", "value": 5, "max": 10}}"#)
        fake.send(id, binary: Data([0, 0, 0, 1, 0, 0, 0, 2]) + tinyPNG)
        let running = try await poll(id, token) { $0["has_preview"] as? Bool == true && $0["current_node"] != nil }
        XCTAssertEqual(running["status"] as? String, "in_progress")
        XCTAssertEqual(running["current_node"] as? String, "Sampler 5/10", "the node's title and its step")
        // Cheap nodes share 10% and the sampler the other 90% (sampling is nearly all of a real run):
        // 4 of the 6 cheap nodes cached + half of the sampler's steps.
        XCTAssertEqual(try XCTUnwrap(running["progress"] as? Double), 0.1 * 4 / 6 + 0.9 * 0.5, accuracy: 0.01)
        XCTAssertNotNil(running["started_at"])
        XCTAssertNotNil(running["eta_seconds"])
        let (preview, previewStatus) = try await client.raw("GET", hubURL.appendingPathComponent("v1/jobs/\(id)/preview"), token: token)
        XCTAssertEqual(previewStatus, 200)
        XCTAssertEqual(preview, tinyPNG)

        fake.slow = false
        let done = try await poll(id, token) { $0["status"] as? String == "completed" }
        XCTAssertEqual(done["progress"] as? Double, 1)
        XCTAssertNil(done["queue_position"])
        XCTAssertEqual(done["has_preview"] as? Bool, false)
        let average = try core.store.averageDuration(model: "comfyui/sdxl")
        XCTAssertNotNil(average, "completed runs feed later ETAs")
    }

    func testSlowSamplerDrivesTheETA() async throws {
        fake.slow = true
        fake.ahead = 1
        let token = try await pair()
        let id = try await startJob(token)
        _ = try await poll(id, token) { $0["queue_position"] as? Int != nil }  // the hub is listening on ComfyUI's socket by now
        fake.ahead = 0
        let promptID = try XCTUnwrap(fake.promptIDs.last)
        fake.send(id, text: #"{"type": "execution_start", "data": {"prompt_id": "\#(promptID)"}}"#)
        fake.send(id, text: #"{"type": "execution_cached", "data": {"prompt_id": "\#(promptID)", "nodes": ["4", "5", "6", "7"]}}"#)
        fake.send(id, text: #"{"type": "executing", "data": {"prompt_id": "\#(promptID)", "node": "3"}}"#)
        for step in 1...5 {
            fake.send(id, text: #"{"type": "progress", "data": {"prompt_id": "\#(promptID)", "node": "3", "value": \#(step), "max": 40}}"#)
            try await Task.sleep(for: .milliseconds(150))
        }
        let running = try await poll(id, token) { $0["current_node"] as? String == "Sampler 5/40" }
        // 0.15 s per step × 35 steps left ≈ 5 s. Counting nodes equally said 0.59 done and an ETA of 0.
        let eta = try XCTUnwrap(running["eta_seconds"] as? Int)
        XCTAssertTrue((4...7).contains(eta), "ETA follows the sampler's step rate: \(running)")
        XCTAssertEqual(try XCTUnwrap(running["progress"] as? Double), 0.1 * 4 / 6 + 0.9 * 5 / 40, accuracy: 0.01)
    }

    func testEstimateWeightsTheSamplerAndTimesItsSteps() {
        // Flux2 Klein edit: loaders and encoders take seconds, the sampler ~21 s a step.
        let nodes: [(id: String, classType: String, title: String?)] = [
            ("1", "UNETLoader", nil), ("2", "CLIPLoader", nil), ("3", "VAELoader", nil), ("4", "LoadImage", nil),
            ("5", "CLIPTextEncode", nil), ("6", "VAEEncode", nil), ("7", "SamplerCustomAdvanced", "Sampler"),
            ("8", "VAEDecode", nil), ("9", "SaveImage", nil)]
        var estimate = JobEstimate(nodes: nodes)
        estimate.cached(["1", "2", "3"])
        for node in ["4", "5", "6", "7"] { estimate.executing(node) }
        let start = Date()
        XCTAssertNil(estimate.eta(elapsed: 40, progress: estimate.progress, average: nil), "nothing to go on yet")
        XCTAssertEqual(estimate.eta(elapsed: 40, progress: estimate.progress, average: 300), 260, "the template's average until steps are timed")
        _ = estimate.step(node: "7", value: 1, max: 12, at: start)
        XCTAssertEqual(estimate.eta(elapsed: 61, progress: estimate.progress, average: 300), 239, "one step is not a rate yet")
        var label: String?
        for step in 2...6 { label = estimate.step(node: "7", value: Double(step), max: 12, at: start.addingTimeInterval(Double(step - 1) * 21)) }
        XCTAssertEqual(label, "Sampler 6/12")
        XCTAssertEqual(estimate.progress, 0.1 * 6 / 8 + 0.9 * 6 / 12, accuracy: 0.001, "not 0.825")
        XCTAssertEqual(estimate.secondsPerStep ?? 0, 21, accuracy: 0.001)
        XCTAssertEqual(estimate.eta(elapsed: 166, progress: estimate.progress, average: 300) ?? 0, 6 * 21, accuracy: 0.001,
                       "the six steps left at the measured rate, not the 28 s node counting gave")

        estimate.executing("8")
        XCTAssertEqual(estimate.progress, 0.1 * 6 / 8 + 0.9, accuracy: 0.001, "sampling done, decode running")
    }

    func testFP8OnMPSFailsAsModelUnsupported() async throws {
        var template = try XCTUnwrap(core.integrations.templates.first { $0.id == "sdxl" })
        template.workflow = template.workflow.replacingOccurrences(of: "sd_xl_base_1.0.safetensors", with: "sdxl-fp8.safetensors")
        try core.integrations.save(template)
        fake.device = "mps"
        let comfy = try XCTUnwrap(core.integrations.list.first { $0.kind == .comfyui })
        let device = await ComfyLibrary(integration: comfy).deviceType()
        XCTAssertEqual(device, "mps")
        XCTAssertNotNil(template.unsupportedModelWarning(device: device), "the Workflows screen and imports warn before anything runs")

        fake.executionError = "Trying to convert Float8_e4m3fn to the MPS backend but it does not have support for that dtype."
        let token = try await pair()
        let id = try await startJob(token)
        let failed = try await poll(id, token) { $0["status"] as? String == "failed" }
        XCTAssertEqual(failed["error_code"] as? String, "model_unsupported", "\(failed)")
        XCTAssertTrue((failed["error"] as? String)?.contains("sdxl-fp8.safetensors") == true, "names the file: \(failed)")

        let (sync, status) = try await client.json("POST", hubURL.appendingPathComponent("v1/images/generations"), token: token,
            body: ["prompt": "a lighthouse"])
        XCTAssertEqual(status, 422)
        let error = try XCTUnwrap(sync["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "model_unsupported")
        XCTAssertEqual(error["provider"] as? String, "comfyui")

        fake.executionError = "Some node exploded"
        let other = try await poll(try await startJob(token), token) { $0["status"] as? String == "failed" }
        XCTAssertEqual(other["error_code"] as? String, "job_failed")
        XCTAssertEqual(other["error"] as? String, "ComfyUI failed: Some node exploded")
    }

    func testTimeoutStopsTheWorkflowInComfyUI() async throws {
        fake.slow = true
        await core.jobs.configureForTesting(timeoutScale: 0.01)  // 1 minute → 0.6 s
        let token = try await pair()
        let id = try await startJob(token)
        let failed = try await poll(id, token) { $0["status"] as? String == "failed" }
        XCTAssertTrue((failed["error"] as? String)?.contains("stopped in ComfyUI") == true, "\(failed)")
        XCTAssertEqual(fake.interrupted, fake.promptIDs, "ComfyUI no longer burns time on a job the hub gave up")
    }

    func testMemoryGuardHoldsTheJobUntilMemoryFreesUp() async throws {
        var settings = try core.store.settings()
        settings.minFreeMemoryGB = 4
        try core.store.save(settings)
        fake.ramFreeGB = 1.5
        let token = try await pair()
        let id = try await startJob(token)
        let waiting = try await poll(id, token) { $0["waiting_reason"] != nil }
        XCTAssertEqual(waiting["status"] as? String, "queued")
        XCTAssertEqual(waiting["waiting_reason"] as? String, "Waiting for memory: 1.5 of 4.0 GB free")
        XCTAssertTrue(fake.prompts.isEmpty, "nothing reaches ComfyUI while memory is short")
        fake.ramFreeGB = 12
        let done = try await poll(id, token) { $0["status"] as? String == "completed" }
        XCTAssertNil(done["waiting_reason"])
    }

    func testInterruptedJobsAreFollowedAgainAfterARestart() async throws {
        let paired = try await pairedDevice(); let device = try XCTUnwrap(paired)
        try core.store.save(HubJob(id: "job-resume", deviceID: device.id, deviceName: device.name, capability: .imageCreate,
            model: "comfyui/sdxl", prompt: "x", status: .inProgress, progress: 0.3, error: nil, outputFileIDs: [],
            createdAt: Date(), finishedAt: nil, startedAt: Date(), promptID: "prompt-from-before", integrationID: "comfyui", templateID: "sdxl"))
        try core.store.save(HubJob(id: "job-lost", deviceID: device.id, deviceName: device.name, capability: .imageCreate,
            model: "comfyui/sdxl", prompt: "y", status: .queued, progress: nil, error: nil, outputFileIDs: [],
            createdAt: Date(), finishedAt: nil, integrationID: "comfyui", templateID: "sdxl"))

        let restarted = try await makeCore()  // a new process opening the same state
        var resumed: HubJob?
        for _ in 0..<60 {
            resumed = try restarted.store.job("job-resume")
            if resumed?.status.isFinished == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(resumed?.status, .completed, "re-attached by prompt id and collected the output")
        XCTAssertEqual(resumed?.outputFileIDs.count, 1)
        let lost = try restarted.store.job("job-lost")
        XCTAssertEqual(lost?.status, .failed)
        XCTAssertEqual(lost?.error, "LocalHub restarted before this job reached ComfyUI")
    }

    private func pairedDevice() async throws -> PairedDevice? {
        _ = try await pair()
        return await core.authority.listDevices().last
    }

    func testDeviceEventStreamCarriesJobsPermissionsAndRevocation() async throws {
        let token = try await pair()
        var request = URLRequest(url: hubURL.appendingPathComponent("v2/events"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await client.session.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let lines = Task { () -> [String] in
            var seen: [String] = []
            for try await line in bytes.lines where line.hasPrefix("event:") {
                seen.append(line)
                if line == "event: revoked" { break }
            }
            return seen
        }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await startJob(token)
        try await Task.sleep(for: .milliseconds(300))
        let devices = await core.authority.listDevices()
        let device = try XCTUnwrap(devices.last)
        try await core.authority.update(device.id) { $0.scopes = ["chat"] }
        try await Task.sleep(for: .milliseconds(200))
        try await core.authority.revoke(device.id)
        let events = try await lines.value
        XCTAssertTrue(events.contains("event: job"), "\(events)")
        XCTAssertTrue(events.contains("event: session"), "\(events)")
        XCTAssertEqual(events.last, "event: revoked")
    }
}

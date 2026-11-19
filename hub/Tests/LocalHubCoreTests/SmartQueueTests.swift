import Foundation
import Vapor
import XCTest
@testable import LocalHubCore

final class SmartQueueTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    private var core: HubCore!
    private var app: Application!
    private var fake: FakeComfy!
    private var integration: ProviderConfiguration!
    private var template: WorkflowTemplate!
    private var first: PairedDevice!
    private var second: PairedDevice!

    override func setUp() async throws {
        directory = try temporaryDirectory()
        core = try HubCore(directory: directory)
        fake = FakeComfy(); fake.slow = true
        app = try await Application.make(.testing); fake.routes(app)
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        integration = ProviderConfiguration(id: "queue", kind: .comfyui, name: "Queue", baseURL: "http://127.0.0.1:\(port)")
        try core.integrations.save(integration)
        let graph = try sample("sdxl-text-to-image.json"), slots = try WorkflowGraph(json: graph).detectSlots()
        template = WorkflowTemplate(id: "queue", name: "Queue", integrationID: "queue", capability: .imageCreate,
                                    workflow: graph, slots: slots.slots, outputNode: slots.outputNode)
        try core.integrations.save(template)
        var settings = HubSettings(); settings.minFreeMemoryGB = 0; settings.queue.paused = true
        try core.store.save(settings)
        first = try await pair("First"); second = try await pair("Second")
    }

    override func tearDown() async throws {
        let open = try core.store.unfinishedJobs()
        for job in open { await core.jobs.cancel(job.id, deviceID: nil) }
        for job in open { _ = await core.jobs.wait(job.id) }
        await app.server.shutdown(); try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func pair(_ name: String) async throws -> PairedDevice {
        let window = await core.authority.openWindow()
        let reply = try await core.authority.pair(code: window.code, deviceName: name, app: "queue-tests", requestedScopes: nil,
                                                grantable: [Capability.imageCreate.rawValue])
        let devices = await core.authority.listDevices()
        return try XCTUnwrap(devices.first { $0.id == reply.deviceID })
    }

    private func submit(_ device: PairedDevice, priority: Int = 0, night: Bool = false) async throws -> HubJob {
        var request = WorkflowJobRequest(prompt: "queue \(UUID())"); request.priority = priority; request.schedule = night ? .night : .anytime
        return try await core.jobs.submit(device: device, template: template, integration: integration, request: request, settings: core.store.settings())
    }

    private func resume() async throws {
        var settings = try core.store.settings(); settings.queue.paused = false
        try core.store.save(settings); await core.jobs.queueSettingsChanged()
    }

    private func waitForPrompt(_ id: String, runner: JobRunner? = nil) async throws -> HubJob {
        let runner = runner ?? core.jobs
        for _ in 0..<80 {
            if let job = await runner.job(id, deviceID: nil), job.promptID != nil { return job }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Job was never dispatched"); throw ConfigurationError.invalid("Test timed out")
    }

    func testPausePriorityFairTurnsAndQueuedCancellation() async throws {
        let a1 = try await submit(first), a2 = try await submit(first), b1 = try await submit(second, priority: 3)
        XCTAssertTrue(fake.prompts.isEmpty)
        XCTAssertEqual(a1.waitingReason, "Local queue paused")
        try await resume()
        _ = try await waitForPrompt(b1.id)
        let waiting = await core.jobs.job(a1.id, deviceID: nil)
        XCTAssertNil(waiting?.dispatchedAt)
        // Cancelling an upstream job releases its slot after cancellation settles.
        await core.jobs.cancel(b1.id, deviceID: nil); _ = await core.jobs.wait(b1.id)
        _ = try await waitForPrompt(a1.id)
        let b2 = try await submit(second)
        await core.jobs.cancel(a1.id, deviceID: nil); _ = await core.jobs.wait(a1.id)
        _ = try await waitForPrompt(b2.id) // second device takes its next turn before First's backlog
        let cancelled = await core.jobs.cancel(a2.id, deviceID: first.id)
        XCTAssertEqual(cancelled?.status, .cancelled)
        XCTAssertNil(cancelled?.promptID)
        XCTAssertEqual(fake.prompts.count, 3)
        XCTAssertEqual(try core.store.job(a2.id)?.status, .cancelled)
    }

    func testNightWindowAndRevocationAreRecheckedBeforeDispatch() async throws {
        var settings = try core.store.settings()
        let hour = Calendar.current.component(.hour, from: Date())
        settings.queue.nightStartHour = (hour + 1) % 24; settings.queue.nightEndHour = (hour + 2) % 24
        try core.store.save(settings)
        let night = try await submit(first, night: true)
        try await resume()
        let waiting = await core.jobs.job(night.id, deviceID: nil)
        XCTAssertNil(waiting?.dispatchedAt); XCTAssertTrue(waiting?.waitingReason?.contains("night hours") == true)
        let revoked = try await submit(second, night: true)
        try await core.authority.revoke(second.id)
        settings = try core.store.settings(); settings.queue.nightEndHour = settings.queue.nightStartHour
        try core.store.save(settings); await core.jobs.queueSettingsChanged()
        _ = try await waitForPrompt(night.id)
        let denied = await core.jobs.job(revoked.id, deviceID: nil)
        XCTAssertEqual(denied?.status, .failed); XCTAssertEqual(denied?.errorCode, "forbidden")
        XCTAssertEqual(fake.prompts.count, 1)
    }

    func testWaitingRecipeSurvivesRestartWithInputAndSeed() async throws {
        let graph = try sample("sdxl-inpaint.json"), slots = try WorkflowGraph(json: graph).detectSlots()
        template = WorkflowTemplate(id: "queue", name: "Edit", integrationID: "queue", capability: .imageCreate,
                                    workflow: graph, slots: slots.slots, outputNode: slots.outputNode)
        try core.integrations.save(template)
        var request = WorkflowJobRequest(prompt: "restart"); request.seed = 123; request.schedule = .night
        request.image = JobInput(data: tinyPNG, filename: "input.png")
        request.mask = JobInput(data: tinyPNG, filename: "mask.png")
        let queued = try await core.jobs.submit(device: first, template: template, integration: integration, request: request, settings: core.store.settings())
        let restored = try HubCore(directory: directory)
        await restored.jobs.resumeInterrupted()
        let recovered = await restored.jobs.job(queued.id, deviceID: nil)
        XCTAssertEqual(recovered?.status, .queued)
        XCTAssertEqual(recovered?.recipe?.parameters.seed, 123)
        XCTAssertEqual(recovered?.schedule, .night)
        XCTAssertEqual(recovered?.recipe?.inputs.count, 2)
        var settings = try core.store.settings(); settings.queue.paused = false
        settings.queue.nightEndHour = settings.queue.nightStartHour
        try core.store.save(settings); await restored.jobs.queueSettingsChanged()
        _ = try await waitForPrompt(queued.id, runner: restored.jobs)
        XCTAssertEqual(fake.prompts.count, 1)
        XCTAssertEqual(fake.uploads.count, 2)
        await restored.jobs.cancel(queued.id, deviceID: nil); _ = await restored.jobs.wait(queued.id)
        // Release the simulated old process's pending task without running it.
        await core.jobs.cancel(queued.id, deviceID: nil)
    }

    func testDeviceConcurrencyAcrossIntegrationsAndGlobalCapacity() async throws {
        let other = ProviderConfiguration(id: "other", kind: .comfyui, name: "Other", baseURL: integration.baseURL)
        try core.integrations.save(other)
        try await core.authority.update(first.id) { $0.maxJobs = 1 }
        let devices = await core.authority.listDevices()
        first = try XCTUnwrap(devices.first { $0.id == first.id })
        let one = try await submit(first)
        var otherTemplate = template!; otherTemplate.id = "other"; otherTemplate.integrationID = "other"
        try core.integrations.save(otherTemplate)
        let two = try await core.jobs.submit(device: first, template: otherTemplate, integration: other,
                                             request: WorkflowJobRequest(prompt: "two"), settings: core.store.settings())
        let three = try await core.jobs.submit(device: second, template: otherTemplate, integration: other,
                                               request: WorkflowJobRequest(prompt: "three"), settings: core.store.settings())
        try await resume()
        _ = try await waitForPrompt(one.id); _ = try await waitForPrompt(three.id)
        let waiting = await core.jobs.job(two.id, deviceID: nil)
        XCTAssertNil(waiting?.dispatchedAt)
        XCTAssertEqual(waiting?.waitingReason, "Waiting for this device's running jobs")
        XCTAssertEqual(fake.prompts.count, 2)
    }

    func testDeletedQueuedInputFailsBeforeComfyUISubmission() async throws {
        let graph = try sample("sdxl-inpaint.json"), slots = try WorkflowGraph(json: graph).detectSlots()
        let edit = WorkflowTemplate(id: "edit", name: "Edit", integrationID: "queue", capability: .imageCreate,
                                    workflow: graph, slots: slots.slots, outputNode: slots.outputNode)
        var request = WorkflowJobRequest(prompt: "edit"); request.image = JobInput(data: tinyPNG, filename: "input.png")
        let job = try await core.jobs.submit(device: first, template: edit, integration: integration, request: request, settings: core.store.settings())
        let input = try XCTUnwrap(job.recipe?.inputs.first)
        try core.files.delete(input.fileID, deviceID: first.id)
        try await resume()
        let failed = await core.jobs.job(job.id, deviceID: nil)
        XCTAssertEqual(failed?.status, .failed); XCTAssertEqual(failed?.errorCode, "recipe_input_missing")
        XCTAssertTrue(fake.prompts.isEmpty)
    }

    func testWindowBoundariesAgingAndBackwardSettings() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: hour))! }
        var queue = QueueSettings()
        XCTAssertTrue(queue.allowsNight(at: date(22), calendar: calendar)); XCTAssertTrue(queue.allowsNight(at: date(0), calendar: calendar))
        XCTAssertFalse(queue.allowsNight(at: date(7), calendar: calendar)); XCTAssertFalse(queue.allowsNight(at: date(21), calendar: calendar))
        queue.nightStartHour = 9; queue.nightEndHour = 17
        XCTAssertTrue(queue.allowsNight(at: date(9), calendar: calendar)); XCTAssertFalse(queue.allowsNight(at: date(17), calendar: calendar))
        queue.maxConcurrent = 0; XCTAssertThrowsError(try queue.validate())
        XCTAssertEqual(try JSONDecoder().decode(HubSettings.self, from: Data("{}".utf8)).queue.maxConcurrent, 2)
        let now = Date()
        func job(_ id: String, age: Double, priority: Int) -> HubJob {
            var value = HubJob(id: id, deviceID: id, deviceName: id, capability: .imageCreate, model: "x", prompt: "x", status: .queued,
                               progress: nil, error: nil, outputFileIDs: [], createdAt: now.addingTimeInterval(-age), finishedAt: nil)
            value.priority = priority; return value
        }
        let old = job("old", age: 6600, priority: -10), urgent = job("urgent", age: 0, priority: 10)
        XCTAssertEqual(QueueOrder.ordered([urgent, old], lastServed: [:], now: now).first?.id, "old")
    }
}

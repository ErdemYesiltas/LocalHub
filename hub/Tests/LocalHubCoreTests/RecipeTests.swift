import Foundation
import Vapor
import XCTest
@testable import LocalHubCore

final class RecipeTests: XCTestCase, @unchecked Sendable {
    private var core: HubCore!
    private var comfy: Application!
    private var fake: FakeComfy!
    private var directory: URL!
    private var integration: ProviderConfiguration!
    private var template: WorkflowTemplate!
    private var device: PairedDevice!
    private var token = ""
    private var settings = HubSettings()

    override func setUp() async throws {
        directory = try temporaryDirectory()
        comfy = try await Application.make(.testing); fake = FakeComfy(); fake.routes(comfy)
        try await comfy.server.start(address: .hostname("127.0.0.1", port: 0))
        core = try HubCore(directory: directory)
        integration = ProviderConfiguration(id: "comfyui", kind: .comfyui, name: "ComfyUI", baseURL: "http://127.0.0.1:\(try XCTUnwrap(comfy.http.server.shared.localAddress?.port))")
        try core.integrations.save(integration)
        let json = try sample("sdxl-text-to-image.json")
        let slots = try WorkflowGraph(json: json).detectSlots()
        template = WorkflowTemplate(id: "recipe-test", name: "Recipe Test", integrationID: integration.id, capability: slots.capability,
            workflow: json, slots: slots.slots, outputNode: slots.outputNode)
        try core.integrations.save(template)
        settings.minFreeMemoryGB = 0; try core.store.save(settings)
        let issued = try await core.authority.issue(name: "Pad", app: "tests", scopes: Capability.allCases.map(\.rawValue))
        token = issued.token
        device = try XCTUnwrap(try core.store.devices().first { $0.id == issued.deviceID })
    }

    override func tearDown() async throws {
        for job in await core.jobs.list(deviceID: nil) where !job.status.isFinished {
            await core.jobs.cancel(job.id, deviceID: nil); _ = await core.jobs.wait(job.id)
        }
        await comfy.server.shutdown(); try await comfy.asyncShutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func submit(_ request: WorkflowJobRequest) async throws -> HubJob {
        try await core.jobs.submit(device: device, template: template, integration: integration, request: request, settings: settings)
    }

    func testResolvedSeedDefaultsAndFullPromptPersistWithTheWorkflow() async throws {
        let prompt = String(repeating: "a watercolor fox ", count: 60)
        let job = try await submit(WorkflowJobRequest(prompt: prompt))
        let recipe = try XCTUnwrap(job.recipe)
        XCTAssertEqual(recipe.parameters.prompt, prompt)
        XCTAssertEqual(recipe.parameters.steps, 25)
        XCTAssertNotNil(recipe.parameters.seed)
        XCTAssertEqual(recipe.workflowVersion, try JobRecipe.version(of: template))
        let finished = await core.jobs.wait(job.id)
        XCTAssertEqual(finished?.status, .completed)
        let graph = try XCTUnwrap(fake.prompts.first)
        let sampler = try XCTUnwrap((graph["3"] as? [String: Any])?["inputs"] as? [String: Any])
        XCTAssertEqual(sampler["seed"] as? Int, recipe.parameters.seed)
        XCTAssertEqual(try core.store.job(job.id)?.recipe, recipe)
        let reopened = try HubStore.open(directory: directory)
        XCTAssertEqual(try reopened.job(job.id)?.recipe?.parameters.prompt, prompt)
    }

    func testOriginalReplayAndVariationPreserveParametersAndLineage() async throws {
        var request = WorkflowJobRequest(prompt: "a lighthouse"); request.seed = 123; request.steps = 7
        let source = try await submit(request); _ = await core.jobs.wait(source.id)
        let replay = try await core.jobs.replay(source.id, deviceID: device.id, as: device, settings: settings)
        XCTAssertEqual(replay.recipe?.parameters, source.recipe?.parameters)
        XCTAssertEqual(replay.recipe?.parentJobID, source.id)
        _ = await core.jobs.wait(replay.id)
        let variation = try await core.jobs.replay(source.id, deviceID: device.id, as: device, variation: true, settings: settings)
        XCTAssertNotEqual(variation.recipe?.parameters.seed, source.recipe?.parameters.seed)
        XCTAssertEqual(variation.recipe?.parameters.steps, 7)
        XCTAssertEqual(variation.recipe?.parameters.prompt, "a lighthouse")
        _ = await core.jobs.wait(variation.id)
    }

    func testRemoteReplayRejectsChangedWorkflowButLocalReplayUsesSavedSnapshot() async throws {
        let source = try await submit(WorkflowJobRequest(prompt: "a fox")); _ = await core.jobs.wait(source.id)
        var changed = template!; changed.name = "Changed workflow"; try core.integrations.save(changed)
        do {
            _ = try await core.jobs.replay(source.id, deviceID: device.id, as: device, settings: settings)
            XCTFail("Remote callers must not restore an unpublished workflow")
        } catch let error as HubError { XCTAssertEqual(error.code, "workflow_changed") }
        let local = try await core.jobs.replay(source.id, deviceID: nil, as: device, settings: settings)
        XCTAssertEqual(local.recipe?.template.name, "Recipe Test")
        XCTAssertEqual(local.recipe?.workflowVersion, source.recipe?.workflowVersion)
        _ = await core.jobs.wait(local.id)
    }

    func testReplayChecksOwnershipPermissionAndLegacyJobs() async throws {
        let source = try await submit(WorkflowJobRequest(prompt: "a fox")); _ = await core.jobs.wait(source.id)
        do { _ = try await core.jobs.replay(source.id, deviceID: "another-device", as: device, settings: settings); XCTFail("Ownership") }
        catch let error as HubError { XCTAssertEqual(error.code, "not_found") }
        var restricted = device!; restricted.scopes = []
        do { _ = try await core.jobs.replay(source.id, deviceID: device.id, as: restricted, settings: settings); XCTFail("Permission") }
        catch let error as HubError { XCTAssertEqual(error.code, "forbidden") }
        var legacy = try XCTUnwrap(try core.store.job(source.id)); legacy.recipe = nil; try core.store.save(legacy)
        XCTAssertNil(try core.store.job(source.id)?.recipe)
        do { _ = try await core.jobs.replay(source.id, deviceID: device.id, as: device, settings: settings); XCTFail("Legacy job") }
        catch let error as HubError { XCTAssertEqual(error.code, "recipe_unavailable") }
    }

    func testInputsSurviveReplayAndMissingInputsFailBeforeSubmitting() async throws {
        let json = try sample("sdxl-inpaint.json"), detected = try WorkflowGraph(json: json).detectSlots()
        template = WorkflowTemplate(id: "recipe-edit", name: "Edit", integrationID: integration.id, capability: .imageEdit,
            workflow: json, slots: detected.slots, outputNode: detected.outputNode)
        try core.integrations.save(template)
        var request = WorkflowJobRequest(prompt: "paint a forest"); request.image = JobInput(data: tinyPNG, filename: "source.png")
        let source = try await submit(request); _ = await core.jobs.wait(source.id)
        let input = try XCTUnwrap(source.recipe?.inputs.first)
        XCTAssertEqual(try core.files.data(core.files.get(input.fileID, deviceID: device.id)), tinyPNG)
        let replay = try await core.jobs.replay(source.id, deviceID: device.id, as: device, settings: settings)
        XCTAssertEqual(replay.recipe?.inputs.first?.fileID, input.fileID)
        _ = await core.jobs.wait(replay.id)
        let stored = try core.files.get(input.fileID, deviceID: device.id)
        try Data("changed content".utf8).write(to: core.files.contentURL(stored))
        do { _ = try await core.jobs.replay(source.id, deviceID: device.id, as: device, settings: settings); XCTFail("Changed input") }
        catch let error as HubError { XCTAssertEqual(error.code, "recipe_input_changed") }
        try core.files.delete(input.fileID, deviceID: device.id)
        let count = fake.prompts.count
        do { _ = try await core.jobs.replay(source.id, deviceID: device.id, as: device, settings: settings); XCTFail("Missing input") }
        catch let error as HubError { XCTAssertEqual(error.code, "recipe_input_missing") }
        XCTAssertEqual(fake.prompts.count, count)
    }

    func testFailedInputRetentionRollsBackAndDoesNotCreateAPhantomJob() async throws {
        let json = try sample("sdxl-inpaint.json"), detected = try WorkflowGraph(json: json).detectSlots()
        template = WorkflowTemplate(id: "quota-edit", name: "Edit", integrationID: integration.id, capability: .imageEdit,
            workflow: json, slots: detected.slots, outputNode: detected.outputNode)
        settings.fileQuotaBytes = tinyPNG.count
        var request = WorkflowJobRequest(prompt: "forest")
        request.image = JobInput(data: tinyPNG, filename: "source.png"); request.mask = JobInput(data: tinyPNG, filename: "mask.png")
        do { _ = try await submit(request); XCTFail("Quota") } catch let error as FileError { XCTAssertEqual(error, .quotaExceeded(limit: tinyPNG.count)) }
        XCTAssertTrue(try core.files.list(deviceID: device.id).isEmpty)
        let jobs = await core.jobs.list(deviceID: device.id)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertTrue(fake.prompts.isEmpty)
    }

    func testRecipeAPIHidesTheGraphAndReplayReturnsANewOwnedJob() async throws {
        let source = try await submit(WorkflowJobRequest(prompt: "a fox")); _ = await core.jobs.wait(source.id)
        let server = HubServer(core: core); try await server.start(settings: settings, portOverride: 0)
        let bound = await server.port
        let url = URL(string: "https://127.0.0.1:\(try XCTUnwrap(bound))/v1/jobs/\(source.id)")!
        let client = PinnedClient(fingerprint: core.certificate.fingerprint)
        do {
            let (recipe, status) = try await client.json("GET", url.appendingPathComponent("recipe"), token: token)
            XCTAssertEqual(status, 200); XCTAssertNil(recipe["template"]); XCTAssertNil(recipe["workflow"])
            XCTAssertEqual(recipe["workflowName"] as? String, "Recipe Test")
            let (replayed, replayStatus) = try await client.json("POST", url.appendingPathComponent("replay"), token: token, body: ["variation": true])
            XCTAssertEqual(replayStatus, 200)
            XCTAssertNotEqual(replayed["id"] as? String, source.id)
            _ = await core.jobs.wait(try XCTUnwrap(replayed["id"] as? String))
        } catch { await server.stop(); throw error }
        await server.stop()
    }
}

import Foundation
import Vapor

public enum JobStatus: String, Codable, Sendable {
    case queued, inProgress = "in_progress", completed, failed, cancelled
    public var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
}

public struct HubJob: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let deviceID: String
    public let deviceName: String
    public let capability: Capability
    /// `<integration>/<template>`.
    public let model: String
    public let prompt: String
    public var status: JobStatus
    /// 0…1 across the whole workflow while running.
    public var progress: Double?
    public var error: String?
    public var outputFileIDs: [String]
    public let createdAt: Date
    public var finishedAt: Date?
    /// When ComfyUI actually started executing it (queued time excluded).
    public var startedAt: Date?
    /// ComfyUI's id, kept so the hub can re-attach after a restart.
    public var promptID: String?
    public var integrationID: String?
    public var templateID: String?
    /// Prompts ahead of this one in ComfyUI's queue (0 = next).
    public var queuePosition: Int?
    /// e.g. `KSampler 12/30`.
    public var currentNode: String?
    public var etaSeconds: Int?
    /// Why a queued job has not started, e.g. waiting for free memory.
    public var waitingReason: String?
    public var previewUpdatedAt: Date?
    /// The hub error code of a failed job, e.g. `model_unsupported`, `insufficient_memory`, `provider_timeout`.
    public var errorCode: String?
    public var recipe: JobRecipe?
    public var priority: Int?
    public var schedule: JobSchedule?
    public var dispatchedAt: Date?

    public init(id: String, deviceID: String, deviceName: String, capability: Capability, model: String, prompt: String,
                status: JobStatus, progress: Double?, error: String?, outputFileIDs: [String], createdAt: Date, finishedAt: Date?,
                startedAt: Date? = nil, promptID: String? = nil, integrationID: String? = nil, templateID: String? = nil) {
        self.id = id; self.deviceID = deviceID; self.deviceName = deviceName; self.capability = capability
        self.model = model; self.prompt = prompt; self.status = status; self.progress = progress; self.error = error
        self.outputFileIDs = outputFileIDs; self.createdAt = createdAt; self.finishedAt = finishedAt
        self.startedAt = startedAt; self.promptID = promptID; self.integrationID = integrationID; self.templateID = templateID
    }

    /// Wall time spent executing (or queued, if it never started).
    public var duration: TimeInterval? {
        guard let end = finishedAt ?? (status.isFinished ? nil : Date()) else { return nil }
        return end.timeIntervalSince(startedAt ?? createdAt)
    }
}

public struct JobInput: Sendable {
    public var data: Data
    public var filename: String
    public var fileID: String?
    public init(data: Data, filename: String, fileID: String? = nil) { self.data = data; self.filename = filename; self.fileID = fileID }
}

/// Values a client may set; each lands in the template slot of the same kind, if mapped.
public struct WorkflowJobRequest: Sendable {
    public var prompt: String
    public var negativePrompt: String?
    public var seed: Int?
    public var steps: Int?
    public var width: Int?
    public var height: Int?
    public var denoise: Double?
    public var seconds: Double?
    public var frames: Int?
    public var fps: Double?
    public var image: JobInput?
    public var mask: JobInput?
    public var audio: JobInput?
    public var video: JobInput?
    public var workProfileID: String?
    public var workProfileName: String?
    public var priority: Int?
    public var schedule: JobSchedule?

    public init(prompt: String) { self.prompt = prompt }
}

/// Runs workflow jobs against ComfyUI. Jobs belong to the device that started
/// them; nobody else can see or cancel them. Long jobs report queue position,
/// the node being executed, previews and an ETA, honour their template's
/// timeout (and stop ComfyUI when it passes), and survive a hub restart.
public actor JobRunner {
    private let store: HubStore
    private let files: FileStore
    private let integrations: IntegrationRegistry
    private var jobs: [String: HubJob] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var watchers: [String: [UUID: AsyncStream<HubJob>.Continuation]] = [:]
    private var listeners: [UUID: AsyncStream<HubJob>.Continuation] = [:]
    private var previews: [String: (data: Data, mime: String)] = [:]
    private struct Tracking { var estimate: JobEstimate; var average: TimeInterval? }
    private var tracking: [String: Tracking] = [:]
    private var lastPersisted: [String: Date] = [:]
    /// Seconds between memory checks while a job waits; tests shorten it.
    private var memoryPollInterval: TimeInterval = 3
    /// Multiplies template timeouts; tests shrink minutes to fractions of a second.
    private var timeoutScale = 1.0
    private struct Pending: Sendable {
        var template: WorkflowTemplate
        var integration: ProviderConfiguration
    }
    private var pending: [String: Pending] = [:]
    private var lastServed: [String: UInt64] = [:]
    private var dispatchCounter: UInt64 = 0
    private var queueWake: Task<Void, Never>?
    private var recovered = false

    func configureForTesting(memoryPollInterval: TimeInterval? = nil, timeoutScale: Double? = nil) {
        if let memoryPollInterval { self.memoryPollInterval = memoryPollInterval }
        if let timeoutScale { self.timeoutScale = timeoutScale }
    }

    init(store: HubStore, files: FileStore, integrations: IntegrationRegistry) {
        self.store = store
        self.files = files
        self.integrations = integrations
    }

    public func submit(device: PairedDevice, template: WorkflowTemplate, integration: ProviderConfiguration,
                       request: WorkflowJobRequest, settings: HubSettings, parentJobID: String? = nil) throws -> HubJob {
        if !recovered { resumeInterrupted() }
        let active = jobs.values.filter { $0.deviceID == device.id && !$0.status.isFinished }.count
        guard active < 100 else {
            throw HubError(.tooManyRequests, "too_many_jobs", "This device already has 100 unfinished jobs; wait or cancel one")
        }
        if let priority = request.priority, !(-10...10).contains(priority) {
            throw HubError(.badRequest, "bad_request", "priority must be -10–10")
        }
        var job = HubJob(id: "job-" + UUID().uuidString.lowercased(), deviceID: device.id, deviceName: device.name,
            capability: template.capability, model: "\(integration.id)/\(template.id)", prompt: String(request.prompt.prefix(500)),
            status: .queued, progress: nil, error: nil, outputFileIDs: [], createdAt: Date(), finishedAt: nil,
            integrationID: integration.id, templateID: template.id)
        job.priority = request.priority; job.schedule = request.schedule
        var retained: [String] = []
        do {
            var recipe = try JobRecipe(template: template, request: request, parentJobID: parentJobID)
            for (kind, input) in [(SlotKind.image, request.image), (.mask, request.mask), (.audio, request.audio), (.video, request.video)] {
                guard let input, template.slot(kind) != nil else { continue }
                let file: HubFile
                if let fileID = input.fileID {
                    file = try files.get(fileID, deviceID: device.id)
                    guard try files.data(file) == input.data else { throw ConfigurationError.invalid("The input file changed before submission") }
                } else {
                    let mime = FileStore.mime(forFilename: input.filename) ?? (kind == .audio ? "audio/wav" : kind == .video ? "video/mp4" : "image/png")
                    file = try files.create(deviceID: device.id, filename: input.filename, mime: mime, data: input.data,
                        purpose: "recipe-input", source: "upload", jobID: job.id, quota: device.effectiveFileQuota(settings), maxBytes: FileStore.maxOutputBytes)
                    retained.append(file.id)
                }
                recipe.inputs.append(RecipeInput(kind: kind, fileID: file.id, filename: file.filename, sha256: JobRecipe.digest(input.data)))
            }
            job.recipe = recipe
            try record(job, force: true)
        } catch {
            for id in retained { try? files.delete(id, deviceID: device.id) }
            throw error
        }
        pending[job.id] = Pending(template: template, integration: integration)
        schedulePending()
        return jobs[job.id] ?? job
    }

    /// `deviceID == nil` is an explicit local-admin replay. Remote callers must
    /// still own the job and may only replay a currently published workflow version.
    public func replay(_ id: String, deviceID: String?, as device: PairedDevice, variation: Bool = false,
                       settings: HubSettings) throws -> HubJob {
        guard let source = job(id, deviceID: deviceID) else { throw HubError(.notFound, "not_found", "No such job") }
        guard deviceID == nil || deviceID == device.id else { throw HubError(.forbidden, "forbidden", "A device can only replay its own jobs") }
        guard source.status.isFinished else { throw HubError(.conflict, "job_active", "Wait for the original job to finish first") }
        guard let recipe = source.recipe, recipe.schemaVersion == 1 else {
            throw HubError(.conflict, "recipe_unavailable", "This job predates production recipes")
        }
        guard device.allows(source.capability.rawValue) else { throw HubError(.forbidden, "forbidden", "This capability is no longer allowed") }
        guard let integration = integrations.list.first(where: { $0.id == recipe.template.integrationID && $0.kind == .comfyui }) else {
            throw HubError(.conflict, "integration_removed", "Reconnect this recipe's ComfyUI integration before replaying")
        }
        if deviceID != nil {
            guard let current = integrations.templates.first(where: { $0.id == recipe.template.id }),
                  try JobRecipe.version(of: current) == recipe.workflowVersion else {
                throw HubError(.conflict, "workflow_changed", "The saved workflow is no longer published. Replay it from LocalHub on the Mac.")
            }
        }
        var request = recipe.parameters.request()
        request.workProfileID = recipe.workProfileID; request.workProfileName = recipe.workProfileName
        request.priority = recipe.priority; request.schedule = recipe.schedule
        if variation {
            guard recipe.template.slot(.seed) != nil else { throw HubError(.conflict, "seed_unavailable", "This workflow has no mapped seed for variations") }
            repeat { request.seed = Int.random(in: 0...Int(UInt32.max)) } while request.seed == recipe.parameters.seed
        }
        for input in recipe.inputs {
            let file: HubFile
            let data: Data
            do {
                file = try files.get(input.fileID, deviceID: source.deviceID)
                data = try files.data(file)
            } catch { throw HubError(.conflict, "recipe_input_missing", "Restore the input file “\(input.filename)” before replaying") }
            guard JobRecipe.digest(data) == input.sha256 else { throw HubError(.conflict, "recipe_input_changed", "The input file “\(input.filename)” no longer matches the recipe") }
            let value = JobInput(data: data, filename: input.filename, fileID: source.deviceID == device.id ? file.id : nil)
            switch input.kind {
            case .image: request.image = value
            case .mask: request.mask = value
            case .audio: request.audio = value
            case .video: request.video = value
            default: break
            }
        }
        return try submit(device: device, template: recipe.template, integration: integration, request: request,
            settings: settings, parentJobID: source.id)
    }

    /// Reattach submitted prompts, restore recipes waiting in the local queue,
    /// and fail ambiguous interrupted submissions rather than producing duplicates.
    public func resumeInterrupted() {
        guard !recovered else { return }
        recovered = true
        let open = (try? store.unfinishedJobs()) ?? []
        let settings = (try? store.settings()) ?? HubSettings()
        for var job in open {
            if job.promptID == nil, job.dispatchedAt == nil, job.status == .queued, let recipe = job.recipe,
               let integration = integrations.list.first(where: { $0.id == job.integrationID }) {
                do {
                    _ = try requestFromRecipe(job)
                    jobs[job.id] = job
                    pending[job.id] = Pending(template: recipe.template, integration: integration)
                } catch {
                    job.status = .failed; job.finishedAt = Date(); job.error = Self.message(error); job.errorCode = "recipe_input_missing"
                    try? record(job, force: true)
                }
                continue
            }
            guard let promptID = job.promptID, let templateID = job.templateID,
                  let template = job.recipe?.template ?? integrations.templates.first(where: { $0.id == templateID }),
                  let integration = integrations.list.first(where: { $0.id == job.integrationID }) else {
                job.status = .failed
                job.error = "LocalHub restarted before this job reached ComfyUI"
                job.finishedAt = Date()
                try? record(job, force: true)
                continue
            }
            job.dispatchedAt = job.dispatchedAt ?? job.startedAt ?? job.createdAt
            jobs[job.id] = job
            let client = ComfyClient(upstream: Upstream(provider: integration))
            let id = job.id
            tasks[id] = Task {
                let device = try? self.store.devices().first { $0.id == job.deviceID }
                await self.follow(id, promptID: promptID, template: template, client: client, quota: device?.effectiveFileQuota(settings) ?? settings.fileQuotaBytes)
            }
        }
        schedulePending()
    }

    /// Call after live settings or device policies change. Also reevaluated on
    /// completion and every 30 seconds while work waits, including after wake.
    public func queueSettingsChanged() { schedulePending() }

    /// Pending jobs retain file references, not potentially gigabytes of input
    /// data in memory. Recheck ownership and hashes immediately before execution.
    private func requestFromRecipe(_ job: HubJob) throws -> WorkflowJobRequest {
        guard let recipe = job.recipe else { throw ConfigurationError.invalid("The job has no recoverable recipe") }
        var request = recipe.parameters.request()
        request.workProfileID = recipe.workProfileID; request.workProfileName = recipe.workProfileName
        request.priority = job.priority; request.schedule = job.schedule
        for input in recipe.inputs {
            let file = try files.get(input.fileID, deviceID: job.deviceID)
            let data = try files.data(file)
            guard JobRecipe.digest(data) == input.sha256 else { throw ConfigurationError.invalid("Recipe input changed") }
            let value = JobInput(data: data, filename: file.filename, fileID: file.id)
            switch input.kind {
            case .image: request.image = value
            case .mask: request.mask = value
            case .audio: request.audio = value
            case .video: request.video = value
            default: break
            }
        }
        return request
    }

    public func setPriority(_ id: String, priority: Int) throws {
        guard (-10...10).contains(priority), pending[id] != nil else {
            throw ConfigurationError.invalid("Only waiting local jobs can be reprioritized (-10–10)")
        }
        update(id) { $0.priority = priority }
        if let job = jobs[id] { try store.save(job) }
        schedulePending()
    }

    private func schedulePending() {
        let settings = (try? store.settings()) ?? HubSettings()
        let devices = (try? store.devices()) ?? []
        let now = Date()
        let ordered = QueueOrder.ordered(pending.keys.compactMap { jobs[$0] }, lastServed: lastServed, now: now)
        for item in ordered {
            guard let work = pending[item.id] else { continue }
            guard let device = devices.first(where: { $0.id == item.deviceID }), device.allows(item.capability.rawValue) else {
                pending[item.id] = nil
                update(item.id) { $0.status = .failed; $0.errorCode = "forbidden"; $0.error = "The device was removed or its workflow permission was revoked" }
                continue
            }
            guard integrations.list.contains(where: { $0.id == work.integration.id && $0.kind == .comfyui }) else {
                pending[item.id] = nil
                update(item.id) { $0.status = .failed; $0.errorCode = "integration_removed"; $0.error = "This job's integration was removed" }
                continue
            }
            let dispatched = jobs.values.filter { $0.dispatchedAt != nil && !$0.status.isFinished }
            let reason: String?
            if settings.queue.paused { reason = "Local queue paused" }
            else if item.schedule == .night && !settings.queue.allowsNight(at: now) { reason = "Waiting for night hours (\(settings.queue.nightStartHour):00–\(settings.queue.nightEndHour):00)" }
            else if dispatched.filter({ $0.deviceID == device.id }).count >= device.effectiveMaxJobs(settings) { reason = "Waiting for this device's running jobs" }
            else if dispatched.count >= settings.queue.maxConcurrent { reason = "Waiting for a free queue slot" }
            else if dispatched.contains(where: { $0.integrationID == item.integrationID }) { reason = "Waiting for this ComfyUI integration" }
            else { reason = nil }
            if let reason {
                if jobs[item.id]?.waitingReason != reason { update(item.id) { $0.waitingReason = reason } }
                continue
            }
            let request: WorkflowJobRequest
            do { request = try requestFromRecipe(item) }
            catch {
                pending[item.id] = nil
                update(item.id) { $0.status = .failed; $0.errorCode = "recipe_input_missing"; $0.error = Self.message(error) }
                continue
            }
            // Reserve before spawning the task, so reentrant submits cannot oversubscribe.
            var dispatchedJob = jobs[item.id] ?? item
            dispatchedJob.dispatchedAt = now; dispatchedJob.waitingReason = nil
            do { try record(dispatchedJob, force: true) }
            catch { continue } // A job is never submitted without a durable dispatch marker.
            pending[item.id] = nil
            dispatchCounter += 1; lastServed[device.id] = dispatchCounter
            let integration = integrations.list.first { $0.id == work.integration.id } ?? work.integration
            let client = ComfyClient(upstream: Upstream(provider: integration))
            tasks[item.id] = Task {
                await self.run(item.id, template: work.template, request: request, client: client,
                    quota: device.effectiveFileQuota(settings), minFreeGB: settings.minFreeMemoryGB)
            }
            // Re-sort after each admission so another device gets its turn,
            // including when several integrations have capacity simultaneously.
            schedulePending()
            return
        }
        if pending.isEmpty { queueWake?.cancel(); queueWake = nil }
        else if queueWake == nil {
            queueWake = Task {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self.queueWake = nil
                self.schedulePending()
            }
        }
    }

    public func job(_ id: String, deviceID: String?) -> HubJob? {
        let job = jobs[id] ?? (try? store.job(id))
        guard let job, deviceID == nil || job.deviceID == deviceID else { return nil }
        return job
    }

    public func list(deviceID: String?, limit: Int = 50) -> [HubJob] {
        ((try? store.jobs(deviceID: deviceID, limit: limit)) ?? []).map { jobs[$0.id] ?? $0 }
    }

    public func preview(_ id: String, deviceID: String?) -> (data: Data, mime: String)? {
        guard job(id, deviceID: deviceID) != nil else { return nil }
        return previews[id]
    }

    @discardableResult
    public func cancel(_ id: String, deviceID: String?) -> HubJob? {
        guard let job = job(id, deviceID: deviceID) else { return nil }
        if !job.status.isFinished {
            if pending.removeValue(forKey: id) != nil { update(id) { $0.status = .cancelled }; schedulePending() }
            else { tasks[id]?.cancel() }
        }
        return self.job(id, deviceID: deviceID) ?? job
    }

    /// Updates for one job until it finishes; the current state is sent first.
    public func updates(_ id: String) -> AsyncStream<HubJob> {
        let (stream, continuation) = AsyncStream<HubJob>.makeStream(bufferingPolicy: .bufferingNewest(32))
        guard let job = job(id, deviceID: nil) else { continuation.finish(); return stream }
        continuation.yield(job)
        if job.status.isFinished { continuation.finish(); return stream }
        let token = UUID()
        watchers[id, default: [:]][token] = continuation
        continuation.onTermination = { _ in Task { await self.unwatch(id, token) } }
        return stream
    }

    /// Every job change: the app's activity views and the per-device event stream.
    public func allUpdates() -> AsyncStream<HubJob> {
        let (stream, continuation) = AsyncStream<HubJob>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let token = UUID()
        listeners[token] = continuation
        continuation.onTermination = { _ in Task { await self.unlisten(token) } }
        return stream
    }

    /// Waits for a job to finish. The job's own template timeout bounds it; cancelling the wait cancels the job.
    public func wait(_ id: String) async -> HubJob? {
        var last: HubJob?
        for await job in updates(id) {
            last = job
            if job.status.isFinished { return job }
            if Task.isCancelled { cancel(id, deviceID: nil) }
        }
        if Task.isCancelled { cancel(id, deviceID: nil) }
        return last
    }

    private func unwatch(_ id: String, _ token: UUID) { watchers[id]?[token] = nil }
    private func unlisten(_ token: UUID) { listeners[token] = nil }

    /// Notifies on every change; writes the database on status changes and at most once a second otherwise.
    private func record(_ job: HubJob, force: Bool = false) throws {
        let previous = jobs[job.id]
        let now = Date()
        if force || previous?.status != job.status || job.status.isFinished
            || now.timeIntervalSince(lastPersisted[job.id] ?? .distantPast) > 1 {
            try store.save(job)
            lastPersisted[job.id] = now
        }
        jobs[job.id] = job
        for continuation in listeners.values { continuation.yield(job) }
        for continuation in watchers[job.id]?.values ?? [:].values {
            continuation.yield(job)
            if job.status.isFinished { continuation.finish() }
        }
        if job.status.isFinished {
            pending[job.id] = nil
            watchers[job.id] = nil
            tasks[job.id] = nil
            jobs[job.id] = nil
            lastPersisted[job.id] = nil
            previews[job.id] = nil
            Task { self.schedulePending() }
        }
    }

    private func update(_ id: String, _ change: (inout HubJob) -> Void) {
        guard var job = jobs[id], !job.status.isFinished else { return }
        change(&job)
        if job.status.isFinished {
            job.finishedAt = Date()
            job.queuePosition = nil; job.waitingReason = nil; job.etaSeconds = nil
        }
        try? record(job)
    }

    private func run(_ id: String, template: WorkflowTemplate, request: WorkflowJobRequest, client: ComfyClient,
                     quota: Int, minFreeGB: Double) async {
        var promptID: String?
        do {
            try await waitForMemory(id, client: client, minFreeGB: minFreeGB, timeout: template.effectiveTimeout * timeoutScale)
            let graph = try WorkflowGraph(json: template.workflow)
            var values: [TemplateSlot: any Sendable] = [:]
            func set(_ kind: SlotKind, _ value: (any Sendable)?) { if let slot = template.slot(kind), let value { values[slot] = value } }
            set(.prompt, request.prompt)
            set(.negativePrompt, request.negativePrompt)
            set(.seed, request.seed ?? Int.random(in: 0...Int(UInt32.max)))
            set(.steps, request.steps)
            set(.width, request.width)
            set(.height, request.height)
            set(.denoise, request.denoise)
            set(.seconds, request.seconds)
            set(.frames, request.frames)
            set(.fps, request.fps)
            for (kind, input) in [(SlotKind.image, request.image), (.mask, request.mask), (.audio, request.audio), (.video, request.video)] {
                if let input, template.slot(kind) != nil { set(kind, try await client.upload(input, as: "localhub-\(id)-\(kind.rawValue)")) }
            }
            try Task.checkCancellation()
            let queued = try await client.queue(try graph.filled(values), clientID: id)
            promptID = queued
            update(id) { $0.promptID = queued; $0.waitingReason = nil }
            if let job = jobs[id] { try? store.save(job) }  // the prompt id must survive a crash right now
            await follow(id, promptID: queued, template: template, client: client, quota: quota)
        } catch {
            await finishWithError(id, error, promptID: promptID, client: client)
        }
    }

    /// Watches a queued prompt to completion: queue position, node progress, previews, ETA, timeout.
    private func follow(_ id: String, promptID: String, template: WorkflowTemplate, client: ComfyClient, quota: Int) async {
        let graph = try? WorkflowGraph(json: template.workflow)
        let average = try? store.averageDuration(model: jobs[id]?.model ?? "")
        let deadline = (jobs[id]?.dispatchedAt ?? jobs[id]?.createdAt ?? Date()).addingTimeInterval(template.effectiveTimeout * timeoutScale)
        tracking[id] = Tracking(estimate: JobEstimate(nodes: graph?.nodeList ?? []), average: average)
        defer { tracking[id] = nil }

        let events = Task {
            await client.watch(clientID: id) { event in await self.apply(event, to: id, promptID: promptID) }
        }
        defer { events.cancel() }
        do {
            var tick = 0
            while true {
                try await Task.sleep(for: .milliseconds(timeoutScale < 1 ? 50 : 800))
                if Date() > deadline {
                    await Task { await client.cancel(promptID: promptID) }.value
                    throw HubError(.gatewayTimeout, "provider_timeout",
                        "The workflow did not finish within \(Int(template.effectiveTimeout / 60)) minutes; it was stopped in ComfyUI",
                        provider: client.upstream.provider.id)
                }
                if let outputs = try await client.outputs(promptID: promptID, template: template) {
                    try await saveOutputs(outputs, for: id, template: template, client: client, quota: quota)
                    return
                }
                tick += 1
                if tick % 2 == 0, jobs[id]?.status == .queued, let position = await client.queuePosition(promptID: promptID) {
                    update(id) { job in
                        if position.running {
                            job.status = .inProgress; job.startedAt = job.startedAt ?? Date(); job.queuePosition = nil
                        } else {
                            job.queuePosition = position.ahead
                            job.etaSeconds = self.tracking[id]?.average.map { Int($0 * Double(position.ahead + 1)) }
                        }
                    }
                }
            }
        } catch {
            await finishWithError(id, error, promptID: promptID, client: client)
        }
    }

    private func apply(_ event: ComfyEvent, to id: String, promptID: String) {
        guard var state = tracking[id] else { return }
        defer { tracking[id] = state }
        switch event {
        case .started(let prompt) where prompt == promptID:
            update(id) { $0.status = .inProgress; $0.startedAt = $0.startedAt ?? Date(); $0.queuePosition = nil; $0.progress = 0 }
        case .cached(let prompt, let nodes) where prompt == promptID:
            state.estimate.cached(nodes)
        case .executing(let prompt, let node) where prompt == promptID:
            state.estimate.executing(node)
            report(id, state, node: node.flatMap { state.estimate.names[$0] })
        case .progress(let prompt, let node, let value, let max) where prompt == nil || prompt == promptID:
            guard max > 0 else { return }
            let label = state.estimate.step(node: node, value: value, max: max, at: Date())
            report(id, state, node: label)
        case .preview(let data, let mime):
            guard jobs[id]?.status == .inProgress else { return }
            previews[id] = (data, mime)
            update(id) { $0.previewUpdatedAt = Date() }
        default:
            break
        }
    }

    private func report(_ id: String, _ state: Tracking, node: String?) {
        update(id) { job in
            if job.status == .queued { job.status = .inProgress; job.startedAt = Date(); job.queuePosition = nil }
            job.progress = max(job.progress ?? 0, state.estimate.progress)
            job.currentNode = node ?? job.currentNode
            let elapsed = Date().timeIntervalSince(job.startedAt ?? Date())
            if let eta = state.estimate.eta(elapsed: elapsed, progress: job.progress ?? 0, average: state.average) {
                job.etaSeconds = Int(eta)
            }
        }
    }

    /// Holds a job in `queued` until ComfyUI's machine has enough free memory (0 disables the check).
    private func waitForMemory(_ id: String, client: ComfyClient, minFreeGB: Double, timeout: TimeInterval) async throws {
        guard minFreeGB > 0 else { return }
        let end = Date().addingTimeInterval(timeout)
        while let free = await client.freeMemoryGB(), free < minFreeGB {
            guard Date() < end else {
                throw HubError(.serviceUnavailable, "insufficient_memory",
                    String(format: "Not enough free memory on the Mac (%.1f GB free, %.1f GB needed)", free, minFreeGB))
            }
            update(id) { $0.waitingReason = String(format: "Waiting for memory: %.1f of %.1f GB free", free, minFreeGB) }
            try await Task.sleep(for: .seconds(memoryPollInterval))
        }
        update(id) { $0.waitingReason = nil }
    }

    private func saveOutputs(_ outputs: [ComfyOutput], for id: String, template: WorkflowTemplate, client: ComfyClient, quota: Int) async throws {
        var fileIDs: [String] = []
        for (index, output) in outputs.enumerated() {
            let (data, mime) = try await client.view(output)
            let ext = FileStore.extensions[mime] ?? "bin"
            let currentOwner = try store.devices().first { $0.id == jobs[id]?.deviceID }
            let effectiveQuota = currentOwner?.effectiveFileQuota(try store.settings()) ?? quota
            let file = try files.create(deviceID: jobs[id]?.deviceID, filename: "\(template.id)-\(id.suffix(8))-\(index + 1).\(ext)",
                mime: mime, data: data, purpose: "output", source: "job", jobID: id, quota: effectiveQuota, maxBytes: FileStore.maxOutputBytes)
            fileIDs.append(file.id)
        }
        guard !fileIDs.isEmpty else { throw HubError(.badGateway, "job_failed", "The workflow finished without an output") }
        update(id) { job in
            job.status = .completed; job.progress = 1; job.outputFileIDs = fileIDs
            job.startedAt = job.startedAt ?? job.createdAt; job.currentNode = nil
        }
    }

    private func finishWithError(_ id: String, _ error: any Error, promptID: String?, client: ComfyClient) async {
        if error is CancellationError || Task.isCancelled {
            // The cancelled task can't make requests any more; stop ComfyUI from a fresh one.
            if let promptID { await Task { await client.cancel(promptID: promptID) }.value }
            update(id) { $0.status = .cancelled }
        } else {
            update(id) {
                $0.status = .failed; $0.error = Self.message(error)
                $0.errorCode = (error as? HubError)?.code ?? (error as? FileError)?.hubError.code
            }
        }
    }

    static func message(_ error: any Error) -> String {
        switch error {
        case let hub as HubError: hub.message
        case FileError.quotaExceeded: "The device's file quota is full; delete files first"
        case let config as ConfigurationError: config.description
        default: error.localizedDescription
        }
    }
}

/// Progress and ETA of a running ComfyUI prompt. Almost all the time of a real workflow is spent in its
/// sampler (Flux2 Klein edit: 20 steps of ~21 s, every other node a few seconds), so counting nodes
/// equally said 0.8 done with half the sampling left. Cheap nodes share `cheapShare`, the sampling nodes
/// (KSampler*, SamplerCustom*, or any node that reports step progress) split the rest by value/max,
/// and the ETA follows the current sampler's measured time per step.
struct JobEstimate: Sendable {
    static let cheapShare = 0.1
    /// Steps that must be timed before the step rate is trusted over the template's average.
    static let stepsBeforeRate = 2.0

    let names: [String: String]
    private let known: Set<String>
    private(set) var samplers: Set<String>
    private var executed: Set<String> = []
    private var current: String?
    private var fraction = 0.0
    /// The first step event seen for the current node: the clock starts there, so model loading and
    /// the first step's warm-up stay out of the rate.
    private var firstStep: (value: Double, at: Date)?
    private var lastStep: (value: Double, max: Double, at: Date)?

    init(nodes: [(id: String, classType: String, title: String?)]) {
        names = Dictionary(nodes.map { ($0.id, $0.title ?? $0.classType) }, uniquingKeysWith: { a, _ in a })
        known = Set(nodes.map(\.id))
        samplers = Set(nodes.filter { $0.classType.hasPrefix("KSampler") || $0.classType.hasPrefix("SamplerCustom") }.map(\.id))
    }

    mutating func cached(_ nodes: [String]) { executed.formUnion(nodes) }

    mutating func executing(_ node: String?) {
        if let current { executed.insert(current) }
        current = node
        fraction = 0
        firstStep = nil
        lastStep = nil
    }

    /// Records a step of the current node and returns its label, e.g. `Sampler 6/20`.
    mutating func step(node: String?, value: Double, max: Double, at now: Date) -> String? {
        let node = node ?? current
        if let node, node != current { executing(node) }
        if let node { samplers.insert(node) }
        if let first = firstStep, value < first.value { firstStep = nil }  // the node started over
        if firstStep == nil { firstStep = (value, now) }
        lastStep = (value, max, now)
        fraction = min(1, value / max)
        return node.flatMap { names[$0] }.map { "\($0) \(Int(value))/\(Int(max))" }
    }

    var progress: Double {
        let heavy = samplers.count
        guard heavy > 0 else {
            return min(0.99, (Double(executed.count) + fraction) / Double(max(1, known.count)))
        }
        let cheapTotal = known.subtracting(samplers).count
        let cheapDone = executed.intersection(known).subtracting(samplers).count
        let currentIsSampler = current.map(samplers.contains) ?? false
        let samplerDone = Double(executed.intersection(samplers).count) + (currentIsSampler ? fraction : 0)
        let cheapShare = cheapTotal == 0 ? 0 : Self.cheapShare
        let cheap = cheapTotal == 0 ? 0 : Double(min(cheapDone, cheapTotal)) / Double(cheapTotal)
        return min(0.99, cheapShare * cheap + (1 - cheapShare) * min(1, samplerDone / Double(heavy)))
    }

    /// Seconds per step of the current sampler, once enough steps have been timed.
    var secondsPerStep: TimeInterval? {
        guard let first = firstStep, let last = lastStep, last.value - first.value >= Self.stepsBeforeRate else { return nil }
        return last.at.timeIntervalSince(first.at) / (last.value - first.value)
    }

    /// The sampler's remaining steps (and those of samplers not started yet, assumed as long) at the
    /// measured rate; before that the template's average run, then extrapolated progress.
    func eta(elapsed: TimeInterval, progress: Double, average: TimeInterval?) -> TimeInterval? {
        if let rate = secondsPerStep, let last = lastStep {
            let waiting = samplers.subtracting(executed).subtracting(current.map { [$0] } ?? []).count
            return max(0, (last.max - last.value) + Double(waiting) * last.max) * rate
        }
        if let average, average > elapsed { return average - elapsed }
        if progress >= 0.1 { return max(0, elapsed / progress - elapsed) }
        return average.map { _ in 0 }
    }
}

struct ComfyOutput: Sendable { let filename: String; let subfolder: String; let type: String }

/// What ComfyUI's WebSocket reports for our client id.
enum ComfyEvent: Sendable {
    case started(promptID: String?)
    case cached(promptID: String?, nodes: [String])
    case executing(promptID: String?, node: String?)
    case progress(promptID: String?, node: String?, value: Double, max: Double)
    case preview(Data, mime: String)
}

/// The fixed set of ComfyUI calls a job makes. Nothing here is reachable by clients directly.
struct ComfyClient: Sendable {
    let upstream: Upstream

    func upload(_ input: JobInput, as name: String) async throws -> String {
        let ext = (input.filename as NSString).pathExtension.lowercased()
        let allowed = ["png", "jpg", "jpeg", "webp", "flac", "wav", "mp3", "ogg", "mp4", "webm", "mov"]
        let filename = "\(name).\(allowed.contains(ext) ? ext : "png")"
        let boundary = "localhub-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(input.data)
        body.append(Data("\r\n".utf8))
        field("type", "input")
        field("overwrite", "true")
        body.append(Data("--\(boundary)--\r\n".utf8))
        let (data, response) = try await upstream.send("POST", "/upload/image", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)", timeout: 60)
        guard response.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = json["name"] as? String else {
            throw HubError(.badGateway, "job_failed", "ComfyUI did not accept the input file", provider: upstream.provider.id)
        }
        let subfolder = json["subfolder"] as? String ?? ""
        return subfolder.isEmpty ? stored : "\(subfolder)/\(stored)"
    }

    func queue(_ workflow: Data, clientID: String) async throws -> String {
        let prompt = try JSONSerialization.jsonObject(with: workflow)
        let body = try JSONSerialization.data(withJSONObject: ["prompt": prompt, "client_id": clientID])
        let (data, response) = try await upstream.send("POST", "/prompt", body: body, contentType: "application/json")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard response.statusCode == 200, let id = json?["prompt_id"] as? String else {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(response.statusCode)"
            throw HubError(.badGateway, "job_failed", "ComfyUI rejected the workflow: \(detail)", provider: upstream.provider.id)
        }
        return id
    }

    /// `nil` while the prompt is still pending or running; outputs once it finished; throws on a ComfyUI error.
    func outputs(promptID: String, template: WorkflowTemplate) async throws -> [ComfyOutput]? {
        let node = template.outputNode
        let (data, response) = try await upstream.send("GET", "/history/\(promptID)")
        guard response.statusCode == 200,
              let entry = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?[promptID] as? [String: Any] else { return nil }
        let status = entry["status"] as? [String: Any]
        if status?["status_str"] as? String == "error" {
            let messages = (status?["messages"] as? [[Any]] ?? []).compactMap { message -> String? in
                guard message.first as? String == "execution_error", let detail = message.last as? [String: Any] else { return nil }
                return detail["exception_message"] as? String
            }
            if let message = messages.first, Self.isFP8OnMPS(message) {
                throw HubError(.unprocessableEntity, "model_unsupported", WorkflowTemplate.fp8Message(template.fp8Models),
                    provider: upstream.provider.id)
            }
            throw HubError(.badGateway, "job_failed", "ComfyUI failed: \(messages.first ?? "execution error")", provider: upstream.provider.id)
        }
        guard status?["completed"] as? Bool ?? true, let outputs = entry["outputs"] as? [String: Any] else { return nil }
        let nodes = node.map { [$0] } ?? outputs.keys.sorted()
        // Any list of `{filename, subfolder, type}`: images, audio, gifs, videos, 3d …
        return nodes.flatMap { id -> [ComfyOutput] in
            (outputs[id] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.flatMap { _, value in
                (value as? [[String: Any]] ?? []).compactMap {
                    guard let filename = $0["filename"] as? String else { return nil }
                    return ComfyOutput(filename: filename, subfolder: $0["subfolder"] as? String ?? "", type: $0["type"] as? String ?? "output")
                }
            }
        }
    }

    /// Prompts ahead in ComfyUI's queue, or `running` when it is the one executing.
    func queuePosition(promptID: String) async -> (running: Bool, ahead: Int)? {
        guard let (data, _) = try? await upstream.send("GET", "/queue"),
              let queue = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let running = queue["queue_running"] as? [[Any]] ?? []
        let pending = queue["queue_pending"] as? [[Any]] ?? []
        if running.contains(where: { $0.count > 1 && $0[1] as? String == promptID }) { return (true, 0) }
        guard let mine = pending.first(where: { $0.count > 1 && $0[1] as? String == promptID }),
              let number = (mine.first as? NSNumber)?.doubleValue else { return nil }
        let before = pending.filter { (($0.first as? NSNumber)?.doubleValue ?? .infinity) < number }.count
        return (false, running.count + before)
    }

    /// e.g. "Trying to convert Float8_e4m3fn to the MPS backend but it does not have support for that dtype."
    static func isFP8OnMPS(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("float8") && lower.contains("mps")
    }

    /// RAM free on ComfyUI's machine (this Mac), from `/system_stats`.
    func freeMemoryGB() async -> Double? {
        guard let (data, response) = try? await upstream.send("GET", "/system_stats", timeout: 5), response.statusCode == 200,
              let system = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["system"] as? [String: Any],
              let free = (system["ram_free"] as? NSNumber)?.doubleValue else { return nil }
        return free / 1_073_741_824
    }

    func view(_ output: ComfyOutput) async throws -> (Data, String) {
        let (data, response) = try await upstream.send("GET", "/view", query: [
            .init(name: "filename", value: output.filename), .init(name: "subfolder", value: output.subfolder),
            .init(name: "type", value: output.type)], timeout: 120, limit: FileStore.maxOutputBytes)
        guard response.statusCode == 200 else {
            throw HubError(.badGateway, "job_failed", "Could not read the workflow output", provider: upstream.provider.id)
        }
        let mime = FileStore.mime(forFilename: output.filename)
            ?? response.value(forHTTPHeaderField: "Content-Type").flatMap { FileStore.extensions[$0] != nil ? $0 : nil } ?? "image/png"
        return (data, mime)
    }

    /// Removes a queued prompt, or interrupts it if it is the one running. Never touches other prompts.
    func cancel(promptID: String) async {
        guard let (data, _) = try? await upstream.send("GET", "/queue"),
              let queue = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        func contains(_ key: String) -> Bool {
            (queue[key] as? [[Any]] ?? []).contains { $0.count > 1 && $0[1] as? String == promptID }
        }
        if contains("queue_running") {
            let body = try? JSONSerialization.data(withJSONObject: ["prompt_id": promptID])
            _ = try? await upstream.send("POST", "/interrupt", body: body, contentType: "application/json")
        } else if contains("queue_pending") {
            let body = try? JSONSerialization.data(withJSONObject: ["delete": [promptID]])
            _ = try? await upstream.send("POST", "/queue", body: body, contentType: "application/json")
        }
    }

    /// ComfyUI's WebSocket for our client id: start, cached nodes, executing node, step progress and
    /// binary preview frames (type 1: image, type 4: image with metadata). Best effort; jobs finish via history.
    func watch(clientID: String, _ handle: @escaping @Sendable (ComfyEvent) async -> Void) async {
        guard var components = URLComponents(string: (try? upstream.url("/ws"))?.absoluteString ?? "") else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [.init(name: "clientId", value: clientID)]
        guard let url = components.url else { return }
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 32 * 1024 * 1024
        socket.resume()
        defer { session.invalidateAndCancel() }
        // `receive()` ignores task cancellation; closing the socket is what ends the wait.
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { return }
                switch message {
                case .string(let text):
                    if let event = Self.parse(text) { await handle(event) }
                case .data(let data):
                    if let event = Self.preview(data) { await handle(event) }
                @unknown default:
                    break
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    static func parse(_ text: String) -> ComfyEvent? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = json["type"] as? String, let data = json["data"] as? [String: Any] else { return nil }
        let prompt = data["prompt_id"] as? String
        switch type {
        case "execution_start": return .started(promptID: prompt)
        case "execution_cached": return .cached(promptID: prompt, nodes: (data["nodes"] as? [Any] ?? []).map { "\($0)" })
        case "executing": return .executing(promptID: prompt, node: data["node"].flatMap { $0 is NSNull ? nil : "\($0)" })
        case "progress":
            guard let value = (data["value"] as? NSNumber)?.doubleValue, let max = (data["max"] as? NSNumber)?.doubleValue else { return nil }
            return .progress(promptID: prompt, node: data["node"].flatMap { $0 is NSNull ? nil : "\($0)" }, value: value, max: max)
        default: return nil
        }
    }

    static func preview(_ data: Data) -> ComfyEvent? {
        guard data.count > 8 else { return nil }
        let bytes = [UInt8](data.prefix(8))
        let type = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        switch type {
        case 1:  // [type][format: 1 jpeg, 2 png][image]
            let format = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
            return .preview(Data(data.dropFirst(8)), mime: format == 2 ? "image/png" : "image/jpeg")
        case 4:  // [type][metadata length][metadata json][image]
            let length = Int(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
            guard data.count > 8 + length else { return nil }
            let metadata = (try? JSONSerialization.jsonObject(with: data.subdata(in: data.startIndex + 8 ..< data.startIndex + 8 + length))) as? [String: Any]
            return .preview(Data(data.dropFirst(8 + length)), mime: metadata?["image_type"] as? String ?? "image/jpeg")
        default:
            return nil
        }
    }
}

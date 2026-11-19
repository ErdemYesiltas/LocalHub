import Foundation
import Vapor

/// A number that may arrive as JSON number or string (OpenAI's videos API sends `"seconds": "8"`).
struct FlexibleDouble: Codable, Sendable {
    let value: Double
    init(value: Double) { self.value = value }
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) { value = number; return }
        guard let number = Double(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number")
        }
        value = number
    }
    func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
}

/// Every media endpoint's body (JSON or multipart). OpenAI fields plus hub extensions
/// (`negative_prompt`, `seed`, `steps`, `strength`, `frames`, `fps`, `*_file_id`).
struct MediaRequest: Content {
    var prompt: String?
    /// `/v1/audio/speech` calls the text `input`.
    var input: String?
    var model: String?
    var profile: String?
    var priority: Int?
    var schedule: JobSchedule?
    var n: Int?
    var size: String?
    var response_format: String?
    var negative_prompt: String?
    var seed: Int?
    var steps: Int?
    var strength: Double?
    var seconds: FlexibleDouble?
    var frames: Int?
    var fps: Double?
    var voice: String?
    var image: File?
    var mask: File?
    var audio: File?
    var input_reference: File?
    var image_file_id: String?
    var mask_file_id: String?
    var audio_file_id: String?
    var video_file_id: String?
}

struct VideoObject: Content {
    struct Failure: Content { var code: String; var message: String }
    var id: String
    var object = "video"
    var status: String
    var progress: Int
    var created_at: Int
    var completed_at: Int?
    var model: String
    var file_id: String?
    var error: Failure?

    init(_ job: HubJob) {
        id = job.id
        switch job.status {
        case .cancelled: status = "failed"; error = Failure(code: "cancelled", message: "The job was cancelled")
        case .failed: status = "failed"; error = Failure(code: job.errorCode ?? "job_failed", message: job.error ?? "The workflow failed")
        default: status = job.status.rawValue
        }
        progress = Int(((job.progress ?? 0) * 100).rounded())
        created_at = Int(job.createdAt.timeIntervalSince1970)
        completed_at = job.finishedAt.map { Int($0.timeIntervalSince1970) }
        model = job.model
        file_id = job.outputFileIDs.first
    }
}

func registerMediaRoutes(_ v1: any RoutesBuilder, core: HubCore) {
    // MARK: Images
    v1.on(.POST, "images", "generations", body: .collect(maxSize: "1mb")) { request async throws -> Response in
        try await respondWithFiles(request, capability: .imageCreate, core: core)
    }
    v1.on(.POST, "images", "edits", body: .collect(maxSize: "40mb")) { request async throws -> Response in
        try await respondWithFiles(request, capability: .imageEdit, core: core)
    }

    // MARK: Audio
    v1.on(.POST, "audio", "speech", body: .collect(maxSize: "1mb")) { request async throws -> Response in
        let (job, wait) = try await submit(request, capability: .audioSpeech, core: core)
        guard wait else { return try await JobObject(job).encodeResponse(status: .accepted, for: request) }
        let finished = try await finish(job, core: core)
        let file = try core.files.get(finished.outputFileIDs[0], deviceID: job.deviceID)
        return Response(status: .ok, headers: ["Content-Type": file.mime], body: .init(data: try core.files.data(file)))
    }
    v1.on(.POST, "audio", "generations", body: .collect(maxSize: "1mb")) { request async throws -> Response in
        try await respondWithFiles(request, capability: .audioCreate, core: core)
    }
    v1.on(.POST, "audio", "edits", body: .collect(maxSize: "100mb")) { request async throws -> Response in
        try await respondWithFiles(request, capability: .audioEdit, core: core)
    }

    // MARK: Transcription (whisper.cpp or an OpenAI-style server)
    v1.on(.POST, "audio", "transcriptions", body: .collect(maxSize: "100mb")) { request async throws -> Response in
        try await request.require(.audioTranscribe)
        struct Form: Content { var file: File; var model: String?; var profile: String?; var language: String?; var prompt: String?; var response_format: String? }
        var form = try request.content.decode(Form.self)
        let profile = try core.store.settings().workProfile(id: form.profile, device: request.device)
        form.model = form.model ?? profile?.models[Capability.audioTranscribe.rawValue]
        let format = form.response_format ?? "json"
        guard ["json", "text", "srt", "vtt", "verbose_json"].contains(format) else {
            throw HubError(.badRequest, "bad_request", "response_format must be json, text, srt, vtt or verbose_json")
        }
        let providers = core.integrations.current.whisper
        let named = form.model.flatMap { model in providers.first { model == $0.id || model.hasPrefix("\($0.id)/") } }
        guard let provider = named ?? providers.first else {
            throw HubError(.notFound, "capability_unavailable", "No transcription app is set up on this Mac; add a Whisper integration in LocalHub")
        }
        let upstreamModel = form.model.flatMap { $0.hasPrefix("\(provider.id)/") ? String($0.dropFirst(provider.id.count + 1)) : nil }
        request.markUsageRecorded()
        let recorder = ChatRecorder(store: core.store, device: try request.device, model: form.model ?? provider.id,
            integrationID: provider.id, request: [:], capability: Capability.audioTranscribe.rawValue)
        do {
            let (body, type) = try await provider.transcribe(audio: Data(form.file.data.readableBytesView), filename: form.file.filename,
                model: upstreamModel, language: form.language, prompt: form.prompt, format: format)
            recorder.received(status: 200); recorder.finish()
            return Response(status: .ok, headers: ["Content-Type": type], body: .init(data: body))
        } catch { recorder.finish(error: error.localizedDescription); throw error }
    }

    // MARK: 3D (extension): image and/or text to a mesh (GLB)
    v1.on(.POST, "3d", "generations", body: .collect(maxSize: "40mb")) { request async throws -> Response in
        try await respondWithFiles(request, capability: .model3DCreate, core: core)
    }

    // MARK: Videos (OpenAI's asynchronous shape)
    v1.on(.POST, "videos", body: .collect(maxSize: "40mb")) { request async throws -> VideoObject in
        VideoObject(try await submit(request, capability: .videoCreate, core: core, forceAsync: true).job)
    }
    v1.get("videos") { request async throws -> OpenAIList<VideoObject> in
        let jobs = await core.jobs.list(deviceID: try request.device.id, limit: 100)
        return OpenAIList(data: jobs.filter { $0.capability == .videoCreate || $0.capability == .videoEdit }.map(VideoObject.init))
    }
    v1.get("videos", ":id") { request async throws -> VideoObject in
        VideoObject(try await ownedVideo(request, core: core))
    }
    v1.get("videos", ":id", "content") { request async throws -> Response in
        let job = try await ownedVideo(request, core: core)
        guard job.status == .completed, let id = job.outputFileIDs.first else {
            throw HubError(.conflict, "not_ready", "The video is \(job.status.rawValue)")
        }
        let file = try core.files.get(id, deviceID: job.deviceID)
        let parts = file.mime.split(separator: "/").map(String.init)
        return try await request.fileio.asyncStreamFile(at: core.files.contentURL(file).path,
            mediaType: HTTPMediaType(type: parts[0], subType: parts.count > 1 ? parts[1] : "octet-stream"))
    }
    v1.delete("videos", ":id") { request async throws -> Response in
        let job = try await ownedVideo(request, core: core)
        if !job.status.isFinished { await core.jobs.cancel(job.id, deviceID: job.deviceID) }
        for id in job.outputFileIDs { try? core.files.delete(id, deviceID: job.deviceID) }
        try core.store.deleteJob(job.id)
        struct Deleted: Content { var id: String; var object = "video"; var deleted = true }
        return try await Deleted(id: job.id).encodeResponse(for: request)
    }
    v1.on(.POST, "videos", ":id", "remix", body: .collect(maxSize: "1mb")) { request async throws -> VideoObject in
        let source = try await ownedVideo(request, core: core)
        guard source.status == .completed, let id = source.outputFileIDs.first else {
            throw HubError(.conflict, "not_ready", "Only a completed video can be remixed")
        }
        let file = try core.files.get(id, deviceID: source.deviceID)
        let input = JobInput(data: try core.files.data(file), filename: file.filename, fileID: file.id)
        return VideoObject(try await submit(request, capability: .videoEdit, core: core, forceAsync: true, video: input).job)
    }
}

private func ownedVideo(_ request: Request, core: HubCore) async throws -> HubJob {
    guard let job = await core.jobs.job(try safeSegment(request.parameters.get("id")), deviceID: try request.device.id),
          job.capability == .videoCreate || job.capability == .videoEdit else {
        throw HubError(.notFound, "not_found", "No such video")
    }
    return job
}

/// Images and audio clips: `{created, data: [{b64_json | url, file_id}]}`, or a 202 job with `Prefer: respond-async`.
private func respondWithFiles(_ request: Request, capability: Capability, core: HubCore) async throws -> Response {
    let (job, wait) = try await submit(request, capability: capability, core: core)
    guard wait else { return try await JobObject(job).encodeResponse(status: .accepted, for: request) }
    let finished = try await finish(job, core: core)
    let format = (try? request.content.get(String.self, at: "response_format")) ?? "b64_json"
    let host = request.headers.first(name: .host) ?? "localhost"
    var items: [ImagesResponse.Item] = []
    for id in finished.outputFileIDs {
        let file = try core.files.get(id, deviceID: job.deviceID)
        items.append(.init(b64_json: format == "url" ? nil : try core.files.data(file).base64EncodedString(),
            url: format == "url" ? "https://\(host)/v1/files/\(id)/content" : nil, file_id: id))
    }
    return try await ImagesResponse(created: Int(finished.createdAt.timeIntervalSince1970), data: items).encodeResponse(for: request)
}

private func finish(_ job: HubJob, core: HubCore) async throws -> HubJob {
    guard let finished = await core.jobs.wait(job.id) else { throw HubError(.internalServerError, "internal_error", "Job vanished") }
    switch finished.status {
    case .completed where !finished.outputFileIDs.isEmpty: return finished
    case .cancelled: throw HubError(.conflict, "job_cancelled", "The job was cancelled")
    default:
        let status: HTTPResponseStatus = switch finished.errorCode {
        case "model_unsupported": .unprocessableEntity
        case "insufficient_memory": .serviceUnavailable
        case "provider_timeout": .gatewayTimeout
        case "quota_exceeded", "payload_too_large": .payloadTooLarge
        default: .badGateway
        }
        throw HubError(status, finished.errorCode ?? "job_failed", finished.error ?? "The workflow failed", provider: finished.integrationID)
    }
}

/// Validates the body, fills a WorkflowJobRequest and starts the job. Returns whether the caller should wait.
private func submit(_ request: Request, capability: Capability, core: HubCore, forceAsync: Bool = false,
                    video: JobInput? = nil) async throws -> (job: HubJob, wait: Bool) {
    try await request.require(capability)
    let device = try request.device
    var input = try request.content.decode(MediaRequest.self)
    let settings = try core.store.settings()
    let profile = try settings.workProfile(id: input.profile, device: device)
    if let profile {
        input.model = input.model ?? profile.models[capability.rawValue]
        input.steps = input.steps ?? profile.steps
        input.negative_prompt = input.negative_prompt ?? profile.negativePrompt
        input.fps = input.fps ?? profile.fps
        if input.size == nil, let width = profile.width, let height = profile.height { input.size = "\(width)x\(height)" }
        if input.seconds == nil, let seconds = profile.seconds { input.seconds = FlexibleDouble(value: seconds) }
    }
    let prompt = (input.prompt ?? input.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let imageOnly = capability == .model3DCreate && (input.image != nil || input.image_file_id != nil) && prompt.isEmpty
    guard imageOnly || (1...4000).contains(prompt.count) else {
        throw HubError(.badRequest, "bad_request", "\(capability == .audioSpeech ? "input" : "prompt") must be 1–4000 characters")
    }
    guard (input.n ?? 1) == 1 else { throw HubError(.badRequest, "bad_request", "Only n=1 is supported") }
    if let format = input.response_format, capability != .audioSpeech, !["b64_json", "url"].contains(format) {
        throw HubError(.badRequest, "bad_request", "response_format must be b64_json or url")
    }
    let (template, integration) = try core.integrations.resolve(capability, model: input.model, defaults: settings.defaults)
    let graph = try WorkflowGraph(json: template.workflow)

    func check<T: Comparable>(_ value: T?, _ range: ClosedRange<T>, _ name: String) throws -> T? {
        guard let value else { return nil }
        guard range.contains(value) else { throw HubError(.badRequest, "bad_request", "\(name) must be \(range.lowerBound)–\(range.upperBound)") }
        return value
    }
    var job = WorkflowJobRequest(prompt: prompt)
    job.workProfileID = profile?.id; job.workProfileName = profile?.name
    job.priority = try check(input.priority ?? profile?.priority, -10...10, "priority")
    job.schedule = input.schedule ?? profile?.schedule
    job.negativePrompt = input.negative_prompt.map { String($0.prefix(4000)) }
    job.seed = try check(input.seed, 0...Int(UInt32.max), "seed")
    job.steps = try check(input.steps, 1...150, "steps")
    job.denoise = try check(input.strength, 0...1, "strength")
    job.fps = try check(input.fps, 1...120, "fps")
    job.frames = try check(input.frames, 1...2000, "frames")
    let seconds = try check(input.seconds?.value, 0.5...600, "seconds")
    if let seconds {
        if template.slot(.seconds) != nil { job.seconds = seconds }
        if job.frames == nil, let framesSlot = template.slot(.frames) {
            let templateFPS = template.slot(.fps).flatMap { (graph.value(of: $0) as? NSNumber)?.doubleValue }
            let fps = job.fps ?? templateFPS ?? 24
            job.frames = max(1, Int((seconds * fps).rounded()) + (graph.classType(of: framesSlot.node)?.contains("Wan") == true ? 1 : 0))
        }
    }
    if let size = input.size, size != "auto" {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts.allSatisfy({ (64...4096).contains($0) && $0 % 8 == 0 }) else {
            throw HubError(.badRequest, "bad_request", "size must be WIDTHxHEIGHT, 64–4096 and multiples of 8")
        }
        job.width = parts[0]; job.height = parts[1]
    }
    job.image = try mediaInput(input.image ?? input.input_reference, fileID: input.image_file_id, kind: "image", device: device, core: core)
    job.mask = try mediaInput(input.mask, fileID: input.mask_file_id, kind: "image", device: device, core: core)
    job.audio = try mediaInput(input.audio, fileID: input.audio_file_id, kind: "audio", device: device, core: core)
    job.video = try video ?? mediaInput(nil, fileID: input.video_file_id, kind: "video", device: device, core: core)
    if let required = capability.requiredInput {
        let provided: JobInput? = switch required { case .image: job.image; case .audio: job.audio; case .video: job.video; default: nil }
        guard provided != nil else {
            throw HubError(.badRequest, "bad_request", "\(capability.title) needs an \(required.rawValue) (upload it or pass \(required.rawValue)_file_id)")
        }
    }
    if capability == .imageEdit {
        if job.mask != nil, template.slot(.mask) == nil {
            throw HubError(.badRequest, "bad_request", "The \(template.name) workflow takes no separate mask; send the mask as the image's alpha channel")
        }
        // OpenAI semantics: without a mask, the image's transparent pixels are the area to edit.
        if job.mask == nil, template.slot(.mask) != nil { job.mask = job.image }
    }

    let submitted: HubJob
    do { submitted = try await core.jobs.submit(device: device, template: template, integration: integration, request: job, settings: settings) }
    catch let error as FileError { throw error.hubError }
    request.markUsageRecorded()
    let async = forceAsync || request.headers.first(name: "Prefer")?.lowercased().contains("respond-async") == true
    return (submitted, !async)
}

private func mediaInput(_ file: File?, fileID: String?, kind: String, device: PairedDevice, core: HubCore) throws -> JobInput? {
    if let file {
        guard file.data.readableBytes <= 100 * 1024 * 1024 else { throw HubError(.payloadTooLarge, "payload_too_large", "The \(kind) exceeds 100 MiB") }
        return JobInput(data: Data(file.data.readableBytesView), filename: file.filename)
    }
    guard let fileID else { return nil }
    do {
        let stored = try core.files.get(try safeSegment(fileID), deviceID: device.id)
        guard stored.mime.hasPrefix("\(kind)/") else { throw HubError(.badRequest, "bad_request", "\(fileID) is not \(kind == "audio" ? "audio" : "an \(kind)")") }
        return JobInput(data: try core.files.data(stored), filename: stored.filename, fileID: stored.id)
    } catch let error as FileError { throw error.hubError }
}

import Foundation
import Vapor

struct FileObject: Content {
    var id: String
    var object = "file"
    var bytes: Int
    var created_at: Int
    var filename: String
    var purpose: String
    var mime_type: String
    var source: String
    var job_id: String?

    init(_ file: HubFile) {
        id = file.id; bytes = file.bytes; created_at = Int(file.createdAt.timeIntervalSince1970)
        filename = file.filename; purpose = file.purpose; mime_type = file.mime; source = file.source; job_id = file.jobID
    }
}

struct JobObject: Content {
    var id: String
    var object = "job"
    var status: String
    var capability: String
    var model: String
    var progress: Double?
    var error: String?
    var output_file_ids: [String]
    var created_at: Int
    var started_at: Int?
    var finished_at: Int?
    /// Prompts ahead in ComfyUI's queue while `queued`.
    var queue_position: Int?
    var current_node: String?
    var eta_seconds: Int?
    var waiting_reason: String?
    var priority: Int?
    var schedule: JobSchedule?
    /// `/v1/jobs/{id}/preview` has a live frame.
    var has_preview: Bool
    /// Set when failed: `model_unsupported`, `insufficient_memory`, `provider_timeout`, `job_failed` …
    var error_code: String?
    var has_recipe: Bool

    init(_ job: HubJob) {
        id = job.id; status = job.status.rawValue; capability = job.capability.rawValue; model = job.model
        progress = job.progress; error = job.error; output_file_ids = job.outputFileIDs
        created_at = Int(job.createdAt.timeIntervalSince1970)
        started_at = job.startedAt.map { Int($0.timeIntervalSince1970) }
        finished_at = job.finishedAt.map { Int($0.timeIntervalSince1970) }
        queue_position = job.queuePosition; current_node = job.currentNode; eta_seconds = job.etaSeconds
        waiting_reason = job.waitingReason; has_preview = job.previewUpdatedAt != nil && !job.status.isFinished
        priority = job.priority; schedule = job.schedule
        error_code = job.status == .failed ? job.errorCode ?? "job_failed" : nil
        has_recipe = job.recipe != nil
    }
}

struct ImagesResponse: Content {
    struct Item: Content { var b64_json: String?; var url: String?; var file_id: String }
    var created: Int
    var data: [Item]
}

struct FileUpload: Content {
    var file: File
    var purpose: String?
}

extension FileError {
    var hubError: HubError {
        switch self {
        case .unsupportedType(let mime): HubError(.unsupportedMediaType, "unsupported_media_type", "Files of type \(mime.isEmpty ? "unknown" : mime) are not accepted")
        case .tooLarge(let limit): HubError(.payloadTooLarge, "payload_too_large", "Files are limited to \(limit / 1_048_576) MiB")
        case .quotaExceeded(let limit): HubError(.payloadTooLarge, "quota_exceeded", "This device's \(limit / 1_048_576) MiB file quota is full; delete files first")
        case .notFound: HubError(.notFound, "not_found", "No such file")
        }
    }
}

func registerCapabilityRoutes(_ protected: any RoutesBuilder, core: HubCore) {
    let v1 = protected.grouped("v1")

    registerMediaRoutes(v1, core: core)

    // MARK: Files
    v1.on(.POST, "files", body: .collect(maxSize: "100mb")) { request async throws -> FileObject in
        let device = try request.device
        let upload = try request.content.decode(FileUpload.self)
        let mime = upload.file.contentType.map { "\($0.type)/\($0.subType)" }
            .flatMap { FileStore.extensions[$0] != nil ? $0 : nil }
            ?? FileStore.mime(forFilename: upload.file.filename) ?? ""
        do {
            return FileObject(try core.files.create(deviceID: device.id, filename: upload.file.filename, mime: mime,
                data: Data(upload.file.data.readableBytesView), purpose: upload.purpose ?? "upload", source: "upload",
                quota: try device.effectiveFileQuota(core.store.settings())))
        } catch let error as FileError { throw error.hubError }
    }
    v1.get("files") { request async throws -> OpenAIList<FileObject> in
        OpenAIList(data: try core.files.list(deviceID: try request.device.id).map(FileObject.init))
    }
    v1.get("files", ":id") { request async throws -> FileObject in
        do { return FileObject(try core.files.get(try safeSegment(request.parameters.get("id")), deviceID: try request.device.id)) }
        catch let error as FileError { throw error.hubError }
    }
    v1.get("files", ":id", "content") { request async throws -> Response in
        let file: HubFile
        do { file = try core.files.get(try safeSegment(request.parameters.get("id")), deviceID: try request.device.id) }
        catch let error as FileError { throw error.hubError }
        let parts = file.mime.split(separator: "/").map(String.init)
        return try await request.fileio.asyncStreamFile(at: core.files.contentURL(file).path,
            mediaType: HTTPMediaType(type: parts[0], subType: parts.count > 1 ? parts[1] : "octet-stream"))
    }
    v1.delete("files", ":id") { request async throws -> DeletedObject in
        let id = try safeSegment(request.parameters.get("id"))
        do { try core.files.delete(id, deviceID: try request.device.id) } catch let error as FileError { throw error.hubError }
        return DeletedObject(id: id)
    }

    // MARK: Jobs (extension)
    v1.get("jobs") { request async throws -> OpenAIList<JobObject> in
        OpenAIList(data: await core.jobs.list(deviceID: try request.device.id).map(JobObject.init))
    }
    v1.get("jobs", ":id") { request async throws -> JobObject in
        guard let job = await core.jobs.job(try safeSegment(request.parameters.get("id")), deviceID: try request.device.id) else {
            throw HubError(.notFound, "not_found", "No such job")
        }
        return JobObject(job)
    }
    v1.post("jobs", ":id", "cancel") { request async throws -> JobObject in
        guard let job = await core.jobs.cancel(try safeSegment(request.parameters.get("id")), deviceID: try request.device.id) else {
            throw HubError(.notFound, "not_found", "No such job")
        }
        return JobObject(job)
    }
    v1.get("jobs", ":id", "recipe") { request async throws -> Response in
        guard let job = await core.jobs.job(try safeSegment(request.parameters.get("id")), deviceID: try request.device.id) else {
            throw HubError(.notFound, "not_found", "No such job")
        }
        guard let recipe = job.recipe else { throw HubError(.notFound, "recipe_unavailable", "This job predates production recipes") }
        return Response(status: .ok, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
            body: .init(data: try JSONEncoder().encode(RecipeSummary(recipe))))
    }
    v1.post("jobs", ":id", "replay") { request async throws -> JobObject in
        struct Replay: Content { var variation: Bool? }
        let options = try request.content.decode(Replay.self)
        let device = try request.device
        do {
            let job = try await core.jobs.replay(try safeSegment(request.parameters.get("id")), deviceID: device.id,
                as: device, variation: options.variation ?? false, settings: core.store.settings())
            request.markUsageRecorded()
            return JobObject(job)
        } catch let error as FileError { throw error.hubError }
    }
    v1.get("jobs", ":id", "preview") { request async throws -> Response in
        guard let preview = await core.jobs.preview(try safeSegment(request.parameters.get("id")), deviceID: try request.device.id) else {
            throw HubError(.notFound, "not_found", "No preview for this job (yet)")
        }
        return Response(status: .ok, headers: ["Content-Type": preview.mime, "Cache-Control": "no-store"], body: .init(data: preview.data))
    }
    v1.get("jobs", ":id", "events") { request async throws -> Response in
        let id = try safeSegment(request.parameters.get("id"))
        guard await core.jobs.job(id, deviceID: try request.device.id) != nil else { throw HubError(.notFound, "not_found", "No such job") }
        let updates = await core.jobs.updates(id)
        let encoder = JSONEncoder()
        return Response(status: .ok, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
            body: .init(managedAsyncStream: { writer in
                for await job in updates {
                    let json = String(decoding: try encoder.encode(JobObject(job)), as: UTF8.self)
                    let event = job.status.isFinished ? job.status.rawValue : "progress"
                    try await writer.writeBuffer(ByteBuffer(string: "event: \(event)\ndata: \(json)\n\n"))
                }
            }))
    }
}

struct DeletedObject: Content {
    var id: String
    var object = "file"
    var deleted = true
}

import Vapor

private struct UsageRecordedKey: StorageKey { typealias Value = Bool }

extension Request {
    func markUsageRecorded() { storage[UsageRecordedKey.self] = true }
}

/// Counts authenticated AI attempts that fail before a recorder/job is created.
/// Successful requests and execution errors are recorded by their own pipeline.
struct UsageFailureMiddleware: AsyncMiddleware {
    let store: HubStore

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let started = Date()
        do { return try await next.respond(to: request) }
        catch {
            if request.storage[UsageRecordedKey.self] != true, request.method == .POST,
               let capability = Self.capability(for: request.url.path), let device = try? request.device {
                let recorder = ChatRecorder(store: store, device: device, model: "unresolved/\(capability)", integrationID: "",
                    request: [:], capability: capability, captureContent: false, startedAt: started)
                recorder.finish(error: "Request rejected")
            }
            throw error
        }
    }

    static func capability(for path: String) -> String? {
        switch path {
        case "/v1/chat/completions", "/lm/v1/chat/completions": return "chat"
        case "/v1/embeddings": return "embeddings"
        case "/v1/images/generations": return "image.create"
        case "/v1/images/edits": return "image.edit"
        case "/v1/audio/speech": return "audio.speech"
        case "/v1/audio/transcriptions": return "audio.transcribe"
        case "/v1/audio/generations": return "audio.create"
        case "/v1/audio/edits": return "audio.edit"
        case "/v1/videos": return "video.create"
        case "/v1/3d/generations": return "3d.create"
        case "/comfy/prompt": return "workflow"
        default:
            let parts = path.split(separator: "/")
            if parts.count == 4, parts[0] == "v1", parts[1] == "videos", parts[3] == "remix" { return "video.edit" }
            if parts.count == 4, parts[0] == "v1", parts[1] == "jobs", parts[3] == "replay" { return "replay" }
            if path.hasSuffix("/call"), path.hasPrefix("/v2/mcp/") || path.hasPrefix("/mcp/") { return "tools" }
            return nil
        }
    }
}

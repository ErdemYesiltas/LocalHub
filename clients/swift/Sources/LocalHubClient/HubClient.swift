import Foundation

public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
    public static func user(_ text: String) -> ChatMessage { .init(role: "user", content: text) }
    public static func system(_ text: String) -> ChatMessage { .init(role: "system", content: text) }
}

public struct ChatRequest: Encodable, Sendable {
    public var model: String?
    public var messages: [ChatMessage]
    public var maxTokens: Int?
    public var temperature: Double?
    /// Hub extension: let the hub run these MCP servers' tools for the model.
    public var mcpServers: [String]?
    public var profile: String?

    public init(model: String? = nil, messages: [ChatMessage], maxTokens: Int? = nil, temperature: Double? = nil, mcpServers: [String]? = nil, profile: String? = nil) {
        self.model = model; self.messages = messages; self.maxTokens = maxTokens; self.temperature = temperature; self.mcpServers = mcpServers
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey { case model, messages, maxTokens = "max_tokens", temperature, mcpServers = "mcp_servers", profile }
}

public struct HubWorkProfile: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let models: [String: String]
    public let steps: Int?
    public let width: Int?
    public let height: Int?
    public let negativePrompt: String?
    public let seconds: Double?
    public let fps: Double?
    public let schedule: String?
    public let priority: Int?
}

/// One streamed piece of a chat reply.
public struct ChatDelta: Sendable, Equatable {
    public var content: String
    public var reasoning: String
    public var finishReason: String?
}

public struct HubModel: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let provider: String
    public let capabilities: [String]
    public let loaded: Bool?
}

public struct HubIntegration: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let kind: String
    public let state: String
    public let detail: String?
}

public struct HubFile: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let bytes: Int
    public let filename: String
    public let purpose: String
    public let mime_type: String
    public let source: String
}

public struct HubJob: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let status: String
    public let capability: String
    public let model: String
    public let progress: Double?
    public let error: String?
    public let output_file_ids: [String]
    public let queue_position: Int?
    public let current_node: String?
    public let eta_seconds: Int?
    public let waiting_reason: String?
    public let schedule: String?
    public let priority: Int?
    public let has_preview: Bool?
    public let has_recipe: Bool?

    public var isFinished: Bool { ["completed", "failed", "cancelled"].contains(status) }
}

public struct HubRecipe: Decodable, Sendable, Equatable {
    public struct Parameters: Decodable, Sendable, Equatable {
        public let prompt: String
        public let negativePrompt: String?
        public let seed: Int?
        public let steps: Int?
        public let width: Int?
        public let height: Int?
        public let denoise: Double?
        public let seconds: Double?
        public let frames: Int?
        public let fps: Double?
    }
    public struct Input: Decodable, Sendable, Equatable {
        public let kind: String
        public let fileID: String
        public let filename: String
        public let sha256: String
    }
    public let schemaVersion: Int
    public let workflowName: String
    public let workflowVersion: String
    public let parameters: Parameters
    public let inputs: [Input]
    public let modelFiles: [String]
    public let parentJobID: String?
    public let workProfileID: String?
    public let workProfileName: String?
}

public struct HubVideo: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let status: String
    public let progress: Int
    public let model: String
    public let file_id: String?
}

/// Result of an image/audio/3D request: the files the hub stored, with inline bytes when asked for.
public struct MediaResult: Sendable, Equatable {
    public struct Item: Sendable, Equatable { public let fileID: String; public let data: Data? }
    public let items: [Item]
}

/// An input file for edits: bytes to upload, or a file already on the hub.
public enum MediaInput: Sendable {
    case data(Data, filename: String, contentType: String)
    case file(id: String)
}

/// LocalHub client for iOS and macOS apps. Pin, token and session live in the `SessionStore` you pass.
public actor HubClient {
    public let store: any SessionStore
    public private(set) var session: HubSession?

    public init(store: any SessionStore) { self.store = store }

    @discardableResult
    public func restore() async throws -> HubSession? {
        session = try await store.load()
        return session
    }

    // MARK: Pairing

    @discardableResult
    public func pair(_ invite: HubInvite, deviceName: String, app: String, scopes: [String]? = nil) async throws -> HubSession {
        struct Body: Encodable { let code: String; let deviceName: String; let app: String; let scopes: [String]? }
        struct Result: Decodable { let deviceID: String; let token: String; let scopes: [String]? }
        let data = try await send(address: invite.address, fingerprint: invite.fingerprint, token: nil, method: "POST",
            path: invite.version == 2 ? "/v2/pair" : "/pair",
            body: .json(try JSONEncoder().encode(Body(code: invite.code, deviceName: deviceName, app: app, scopes: scopes))))
        let result = try JSONDecoder().decode(Result.self, from: data)
        let paired = HubSession(address: invite.address, fingerprint: invite.fingerprint, token: result.token,
            deviceID: result.deviceID, scopes: result.scopes ?? [], hubID: invite.hubID, hubName: invite.hubName)
        try await store.save(paired)
        session = paired
        return paired
    }

    public func unpair() async throws {
        if session != nil {
            do { _ = try await call("DELETE", "/v2/session") }
            catch HubClientError.hub(401, _, _, _) {}
        }
        try await store.clear()
        session = nil
    }

    /// Finds the paired hub again after its IP changed (Bonjour, matched by hub id and the pinned fingerprint).
    /// Saves and returns the new address, or `nil`. Requests do this once on their own when the hub is unreachable.
    @discardableResult
    public func relocate(timeout: Duration = .milliseconds(2500)) async throws -> URL? {
        let current = try requireSession()
        guard let hubID = current.hubID,
              let hub = await discoverHubs(timeout: timeout).first(where: { $0.id == hubID && $0.fingerprint == current.fingerprint }),
              let address = URL(string: "https://\(hub.host):\(hub.port)"), address != current.address else { return nil }
        var moved = current
        moved.address = address
        try await store.save(moved)
        session = moved
        return address
    }

    // MARK: Discovery

    public func models() async throws -> [HubModel] {
        struct List: Decodable { let data: [HubModel] }
        return try JSONDecoder().decode(List.self, from: try await call("GET", "/v1/models")).data
    }

    public func integrations() async throws -> [HubIntegration] {
        try JSONDecoder().decode([HubIntegration].self, from: try await call("GET", "/v2/integrations"))
    }

    public func workProfiles() async throws -> [HubWorkProfile] {
        try JSONDecoder().decode([HubWorkProfile].self, from: try await call("GET", "/v2/profiles"))
    }

    // MARK: Chat

    /// The full completion as returned by the hub (OpenAI's shape).
    public func chat(_ request: ChatRequest) async throws -> String {
        struct Reply: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }; let choices: [Choice] }
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        body["stream"] = false
        let data = try await call("POST", "/v1/chat/completions", body: .json(try JSONSerialization.data(withJSONObject: body)))
        return try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content ?? ""
    }

    /// Streamed reply. Cancelling the consuming task closes the connection; the hub stops the generation.
    public func chatStream(_ request: ChatRequest) throws -> AsyncThrowingStream<ChatDelta, Error> {
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        body["stream"] = true
        let payload = try JSONSerialization.data(withJSONObject: body)
        return events("POST", "/v1/chat/completions", body: .json(payload)) { data in
            guard data != "[DONE]", let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                  let choice = (json["choices"] as? [[String: Any]])?.first else { return nil }
            let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
            return ChatDelta(content: delta["content"] as? String ?? "", reasoning: delta["reasoning_content"] as? String ?? "",
                finishReason: choice["finish_reason"] as? String)
        }
    }

    public func embeddings(model: String, input: [String], profile: String? = nil) async throws -> [[Double]] {
        struct Reply: Decodable { struct Item: Decodable { let embedding: [Double] }; let data: [Item] }
        let body = try JSONSerialization.data(withJSONObject: Self.clean(["model": model, "input": input, "profile": profile]))
        return try JSONDecoder().decode(Reply.self, from: try await call("POST", "/v1/embeddings", body: .json(body))).data.map(\.embedding)
    }

    // MARK: Media

    /// Waits for the image (up to the Mac's workflow timeout). Use `startImage` for a job you can follow and cancel.
    public func generateImage(prompt: String, model: String? = nil, size: String? = nil, extra: [String: Any] = [:], profile: String? = nil) async throws -> MediaResult {
        try await media("/v1/images/generations", fields: Self.merged(extra, ["prompt": prompt, "model": model, "size": size, "profile": profile]))
    }

    public func editImage(prompt: String, image: MediaInput, mask: MediaInput? = nil, model: String? = nil, extra: [String: Any] = [:], profile: String? = nil) async throws -> MediaResult {
        try await media("/v1/images/edits", fields: Self.merged(extra, ["prompt": prompt, "model": model, "profile": profile]),
            inputs: ["image": image, "mask": mask].compactMapValues { $0 })
    }

    public func startImage(prompt: String, model: String? = nil, extra: [String: Any] = [:], profile: String? = nil) async throws -> HubJob {
        let body = try JSONSerialization.data(withJSONObject: Self.clean(Self.merged(extra, ["prompt": prompt, "model": model, "profile": profile])))
        return try JSONDecoder().decode(HubJob.self, from: try await call("POST", "/v1/images/generations", body: .json(body),
            headers: ["Prefer": "respond-async"]))
    }

    public func generateAudio(prompt: String, seconds: Double? = nil, model: String? = nil, profile: String? = nil) async throws -> MediaResult {
        try await media("/v1/audio/generations", fields: ["prompt": prompt, "seconds": seconds, "model": model, "profile": profile])
    }

    public func generate3D(image: MediaInput, prompt: String? = nil, model: String? = nil, profile: String? = nil) async throws -> MediaResult {
        try await media("/v1/3d/generations", fields: ["prompt": prompt, "model": model, "profile": profile], inputs: ["image": image])
    }

    /// Spoken audio bytes and their content type.
    public func speech(_ text: String, voice: String? = nil, model: String? = nil, profile: String? = nil) async throws -> (data: Data, contentType: String) {
        let body = try JSONSerialization.data(withJSONObject: Self.clean(["input": text, "voice": voice, "model": model, "profile": profile]))
        let (data, response) = try await raw("POST", "/v1/audio/speech", body: .json(body))
        return (data, response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
    }

    public func transcribe(_ audio: Data, filename: String = "audio.wav", model: String? = nil, language: String? = nil, profile: String? = nil) async throws -> String {
        struct Reply: Decodable { let text: String }
        let fields = Self.clean(["model": model, "language": language, "profile": profile]).mapValues { "\($0)" }
        let data = try await call("POST", "/v1/audio/transcriptions",
            body: .multipart(fields: fields, files: [("file", filename, "application/octet-stream", audio)]))
        return try JSONDecoder().decode(Reply.self, from: data).text
    }

    public func createVideo(prompt: String, seconds: Double? = nil, size: String? = nil, model: String? = nil, profile: String? = nil) async throws -> HubVideo {
        let body = try JSONSerialization.data(withJSONObject: Self.clean(["prompt": prompt, "seconds": seconds, "size": size, "model": model, "profile": profile]))
        return try JSONDecoder().decode(HubVideo.self, from: try await call("POST", "/v1/videos", body: .json(body)))
    }

    public func video(_ id: String) async throws -> HubVideo {
        try JSONDecoder().decode(HubVideo.self, from: try await call("GET", "/v1/videos/\(Self.segment(id))"))
    }

    public func videoContent(_ id: String) async throws -> Data { try await call("GET", "/v1/videos/\(Self.segment(id))/content") }

    // MARK: Files and jobs

    public func uploadFile(_ data: Data, filename: String, contentType: String, purpose: String? = nil) async throws -> HubFile {
        let fields = purpose.map { ["purpose": $0] } ?? [:]
        return try JSONDecoder().decode(HubFile.self, from: try await call("POST", "/v1/files",
            body: .multipart(fields: fields, files: [("file", filename, contentType, data)])))
    }

    public func files() async throws -> [HubFile] {
        struct List: Decodable { let data: [HubFile] }
        return try JSONDecoder().decode(List.self, from: try await call("GET", "/v1/files")).data
    }

    public func fileContent(_ id: String) async throws -> Data { try await call("GET", "/v1/files/\(Self.segment(id))/content") }

    public func deleteFile(_ id: String) async throws { _ = try await call("DELETE", "/v1/files/\(Self.segment(id))") }

    public func job(_ id: String) async throws -> HubJob {
        try JSONDecoder().decode(HubJob.self, from: try await call("GET", "/v1/jobs/\(Self.segment(id))"))
    }

    public func cancelJob(_ id: String) async throws -> HubJob {
        try JSONDecoder().decode(HubJob.self, from: try await call("POST", "/v1/jobs/\(Self.segment(id))/cancel"))
    }

    public func recipe(_ id: String) async throws -> HubRecipe {
        try JSONDecoder().decode(HubRecipe.self, from: try await call("GET", "/v1/jobs/\(Self.segment(id))/recipe"))
    }

    public func replayJob(_ id: String, variation: Bool = false) async throws -> HubJob {
        let body = try JSONSerialization.data(withJSONObject: ["variation": variation])
        return try JSONDecoder().decode(HubJob.self, from: try await call("POST", "/v1/jobs/\(Self.segment(id))/replay", body: .json(body)))
    }

    /// The live preview frame of a running job, if any.
    public func jobPreview(_ id: String) async throws -> Data? {
        do { return try await call("GET", "/v1/jobs/\(Self.segment(id))/preview") }
        catch HubClientError.hub(404, _, _, _) { return nil }
    }

    /// Job snapshots until it finishes.
    public func jobEvents(_ id: String) -> AsyncThrowingStream<HubJob, Error> {
        events("GET", "/v1/jobs/\(Self.segment(id))/events", body: nil) { data in
            try? JSONDecoder().decode(HubJob.self, from: Data(data.utf8))
        }
    }

    // MARK: Plumbing

    enum Body {
        case json(Data)
        case multipart(fields: [String: String], files: [(name: String, filename: String, contentType: String, data: Data)])
    }

    private func media(_ path: String, fields: [String: Any?], inputs: [String: MediaInput] = [:]) async throws -> MediaResult {
        struct Reply: Decodable { struct Item: Decodable { let b64_json: String?; let file_id: String }; let data: [Item] }
        var fields = Self.clean(fields)
        var files: [(String, String, String, Data)] = []
        for (name, input) in inputs {
            switch input {
            case .data(let data, let filename, let type): files.append((name, filename, type, data))
            case .file(let id): fields["\(name == "input_reference" ? "image" : name)_file_id"] = id
            }
        }
        let body: Body = files.isEmpty ? .json(try JSONSerialization.data(withJSONObject: fields))
            : .multipart(fields: fields.mapValues { "\($0)" }, files: files)
        let reply = try JSONDecoder().decode(Reply.self, from: try await call("POST", path, body: body, timeout: 660))
        return MediaResult(items: reply.data.map { .init(fileID: $0.file_id, data: $0.b64_json.flatMap { Data(base64Encoded: $0) }) })
    }

    private static func clean(_ fields: [String: Any?]) -> [String: Any] { fields.compactMapValues { $0 } }

    private static func merged(_ extra: [String: Any], _ fields: [String: Any?]) -> [String: Any?] {
        extra.mapValues { Optional($0) }.merging(fields) { _, new in new }
    }

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? value
    }

    private func requireSession() throws -> HubSession {
        guard let session else { throw HubClientError.notPaired }
        return session
    }

    func call(_ method: String, _ path: String, body: Body? = nil, headers: [String: String] = [:], timeout: TimeInterval = 120) async throws -> Data {
        try await raw(method, path, body: body, headers: headers, timeout: timeout).0
    }

    private func raw(_ method: String, _ path: String, body: Body? = nil, headers: [String: String] = [:], timeout: TimeInterval = 120) async throws -> (Data, HTTPURLResponse) {
        let session = try requireSession()
        do {
            return try await exchange(address: session.address, fingerprint: session.fingerprint, token: session.token,
                method: method, path: path, body: body, headers: headers, timeout: timeout)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
            guard try await relocate() != nil, let moved = self.session else { throw error }
            return try await exchange(address: moved.address, fingerprint: moved.fingerprint, token: moved.token,
                method: method, path: path, body: body, headers: headers, timeout: timeout)
        }
    }

    private func send(address: URL, fingerprint: String, token: String?, method: String, path: String, body: Body?) async throws -> Data {
        try await exchange(address: address, fingerprint: fingerprint, token: token, method: method, path: path, body: body, headers: [:], timeout: 60).0
    }

    private func exchange(address: URL, fingerprint: String, token: String?, method: String, path: String, body: Body?,
                          headers: [String: String], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let (request, delegate, urlSession) = try makeRequest(address: address, fingerprint: fingerprint, token: token,
            method: method, path: path, body: body, headers: headers, timeout: timeout)
        defer { urlSession.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await urlSession.data(for: request) }
        catch { if delegate.sawMismatch { throw HubClientError.pinMismatch }; throw error }
        guard let http = response as? HTTPURLResponse else { throw HubClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(http.statusCode, data) }
        return (data, http)
    }

    nonisolated private func makeRequest(address: URL, fingerprint: String, token: String?, method: String, path: String, body: Body?,
                             headers: [String: String], timeout: TimeInterval) throws -> (URLRequest, PinningDelegate, URLSession) {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: path, relativeTo: address)?.absoluteURL,
              url.host == address.host, url.port == address.port else { throw HubClientError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        switch body {
        case .json(let data):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        case .multipart(let fields, let files):
            let boundary = "localhub-\(UUID().uuidString)"
            var data = Data()
            func clean(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
            for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(clean(name))\"\r\n\r\n\(value)\r\n".utf8))
            }
            for file in files {
                data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(clean(file.name))\"; filename=\"\(clean(file.filename))\"\r\nContent-Type: \(file.contentType)\r\n\r\n".utf8))
                data.append(file.data)
                data.append(Data("\r\n".utf8))
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        case nil:
            break
        }
        let delegate = PinningDelegate(fingerprint: fingerprint, address: address)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.urlCache = nil
        return (request, delegate, URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil))
    }

    /// Server-sent events: each `data:` line through `decode`; the stream ends with the response.
    private func events<T: Sendable>(_ method: String, _ path: String, body: Body?,
                                     decode: @escaping @Sendable (String) -> T?) -> AsyncThrowingStream<T, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let session else { throw HubClientError.notPaired }
                    let (request, delegate, urlSession) = try makeRequest(address: session.address, fingerprint: session.fingerprint,
                        token: session.token, method: method, path: path, body: body, headers: ["Accept": "text/event-stream"], timeout: 660)
                    defer { urlSession.invalidateAndCancel() }
                    let bytes: URLSession.AsyncBytes, response: URLResponse
                    do { (bytes, response) = try await urlSession.bytes(for: request) }
                    catch { if delegate.sawMismatch { throw HubClientError.pinMismatch }; throw error }
                    guard let http = response as? HTTPURLResponse else { throw HubClientError.badResponse }
                    guard http.statusCode == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count > 65536 { break } }
                        throw Self.error(http.statusCode, data)
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let value = decode(payload) { continuation.yield(value) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func error(_ status: Int, _ data: Data) -> HubClientError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] as? [String: Any],
           let code = error["code"] as? String, let message = error["message"] as? String {
            return .hub(status: status, code: code, message: message, provider: error["provider"] as? String)
        }
        return .hub(status: status, code: "http_error", message: "LocalHub HTTP \(status)", provider: nil)
    }
}

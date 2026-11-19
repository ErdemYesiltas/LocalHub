import Foundation
import GRDB

/// One chat completion as the Mac sees it. Never readable through the client API.
public struct ChatLog: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chatlog"

    public var id: String
    public var deviceID: String
    public var deviceName: String
    public var app: String
    /// What the client asked for, e.g. `lmstudio/qwen/qwen3-8b`.
    public var model: String
    public var integrationID: String
    /// The request's `messages` as JSON, inline images replaced by a placeholder.
    public var messages: String
    /// Searchable text of every message.
    public var prompt: String
    public var response: String
    /// Reasoning text from thinking models (`reasoning_content`), kept apart from the reply.
    public var reasoning: String
    public var finishReason: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var durationMs: Int
    /// `completed`, `error` or `interrupted` (client went away mid-stream).
    public var status: String
    public var error: String?
    public var stream: Bool
    public var createdAt: Date

    public init(id: String, deviceID: String, deviceName: String, app: String, model: String, integrationID: String,
                messages: String, prompt: String, response: String, reasoning: String = "", finishReason: String?, promptTokens: Int?,
                completionTokens: Int?, durationMs: Int, status: String, error: String?, stream: Bool, createdAt: Date) {
        self.id = id; self.deviceID = deviceID; self.deviceName = deviceName; self.app = app; self.model = model
        self.integrationID = integrationID; self.messages = messages; self.prompt = prompt; self.response = response; self.reasoning = reasoning
        self.finishReason = finishReason; self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.durationMs = durationMs; self.status = status; self.error = error; self.stream = stream; self.createdAt = createdAt
    }

    public struct Message: Sendable, Equatable, Identifiable {
        public let id: Int
        public let role: String
        public let text: String
    }

    /// Messages for display: text parts joined, images shown as `[image]`.
    public var decodedMessages: [Message] {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(messages.utf8))) as? [[String: Any]] else { return [] }
        return array.enumerated().map { index, message in
            Message(id: index, role: message["role"] as? String ?? "?", text: ChatLog.text(of: message["content"]))
        }
    }

    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.map { part in
            if let text = part["text"] as? String { return text }
            return part["type"] as? String == "image_url" ? "[image]" : ""
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension HubStore {
    static func registerChatLogMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-chatlogs") { db in
            try db.create(table: "chatlog") { t in
                t.primaryKey("id", .text)
                t.column("deviceID", .text).notNull().indexed()
                t.column("deviceName", .text).notNull()
                t.column("app", .text).notNull()
                t.column("model", .text).notNull()
                t.column("integrationID", .text).notNull()
                t.column("messages", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("response", .text).notNull()
                t.column("reasoning", .text).notNull().defaults(to: "")
                t.column("finishReason", .text)
                t.column("promptTokens", .integer)
                t.column("completionTokens", .integer)
                t.column("durationMs", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("error", .text)
                t.column("stream", .boolean).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
            }
            try db.create(virtualTable: "chatlog_ft", using: FTS5()) { t in
                t.synchronize(withTable: "chatlog")
                t.tokenizer = .unicode61()
                t.column("prompt")
                t.column("response")
            }
        }
    }

    public func save(_ log: ChatLog) throws {
        try recordChat(log, retainContent: true)
    }

    /// Newest first. `search` matches word prefixes in prompts and responses.
    public func chatLogs(deviceID: String? = nil, search: String? = nil, limit: Int = 200) throws -> [ChatLog] {
        try database.read { db in
            var conditions: [String] = []
            var arguments: StatementArguments = []
            var sql = "SELECT chatlog.* FROM chatlog"
            if let search, let pattern = FTS5Pattern(matchingAllPrefixesIn: search) {
                sql += " JOIN chatlog_ft ON chatlog_ft.rowid = chatlog.rowid AND chatlog_ft MATCH ?"
                arguments += [pattern]
            }
            if let deviceID { conditions.append("chatlog.deviceID = ?"); arguments += [deviceID] }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " ORDER BY chatlog.createdAt DESC LIMIT ?"
            arguments += [limit]
            return try ChatLog.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    public func deleteChatLog(_ id: String) throws {
        _ = try database.write { try ChatLog.deleteOne($0, key: id) }
    }

    public func deleteChatLogs(deviceID: String) throws {
        _ = try database.write { try ChatLog.filter(Column("deviceID") == deviceID).deleteAll($0) }
    }

    @discardableResult
    public func purgeChatLogs(olderThan date: Date) throws -> Int {
        try database.write { try ChatLog.filter(Column("createdAt") < date).deleteAll($0) }
    }
}

/// Collects one chat completion while it is forwarded and stores it when it ends.
/// Both buffered JSON and SSE streams are parsed after the fact from the raw bytes.
final class ChatRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HubStore
    private let retainContent: Bool
    private let usageCapability: String
    private var metricsBody = Data()
    private var metricsSSE = false
    private var observedPromptTokens: Int?
    private var observedCompletionTokens: Int?
    private var toolPromptTokens: Int?
    private var toolCompletionTokens: Int?
    private var log: ChatLog
    private var body = Data()
    private var httpStatus = 0
    private var done = false
    private let started: Date
    static let captureLimit = 2 * 1024 * 1024

    init(store: HubStore, device: PairedDevice, model: String, integrationID: String, request: [String: Any], capability: String = "chat", captureContent: Bool? = nil, startedAt: Date? = nil) {
        self.store = store
        started = startedAt ?? Date()
        retainContent = captureContent ?? (device.logging && capability == "chat")
        usageCapability = capability
        let messages = retainContent ? Self.redacted(request["messages"]) as? [Any] ?? [] : []
        let json = (try? JSONSerialization.data(withJSONObject: messages)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let prompt = messages.compactMap { ($0 as? [String: Any]).map { ChatLog.text(of: $0["content"]) } }.joined(separator: "\n")
        log = ChatLog(id: "chat-" + UUID().uuidString.lowercased(), deviceID: device.id, deviceName: device.name, app: device.app,
            model: model, integrationID: integrationID, messages: json, prompt: prompt, response: "", reasoning: "", finishReason: nil,
            promptTokens: nil, completionTokens: nil, durationMs: 0, status: "completed", error: nil,
            stream: request["stream"] as? Bool ?? false, createdAt: started)
    }

    func received(status: Int, streaming: Bool = false) { lock.withLock { httpStatus = status; metricsSSE = streaming } }

    func append(_ data: Data) {
        lock.withLock {
            if retainContent, body.count < Self.captureLimit { body.append(data.prefix(Self.captureLimit - body.count)) }
            if metricsSSE {
                metricsBody.append(data)
                while let end = metricsBody.firstIndex(of: 10) {
                    let line = String(decoding: metricsBody[..<end], as: UTF8.self)
                    metricsBody.removeSubrange(...end)
                    if line.hasPrefix("data:") { observeUsage(Data(line.dropFirst(5).utf8)) }
                }
                if metricsBody.count > Self.captureLimit { metricsBody.removeAll(keepingCapacity: false) }
            } else if metricsBody.count < Upstream.responseLimit {
                metricsBody.append(data.prefix(Upstream.responseLimit - metricsBody.count))
            }
        }
    }

    private func observeUsage(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let usage = json["usage"] as? [String: Any] else { return }
        observedPromptTokens = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? observedPromptTokens
        observedCompletionTokens = (usage["completion_tokens"] as? NSNumber)?.intValue ?? observedCompletionTokens
    }

    func recordToolUsage(_ json: [String: Any]) {
        lock.withLock {
            guard let usage = json["usage"] as? [String: Any] else { return }
            if let count = (usage["prompt_tokens"] as? NSNumber)?.intValue { toolPromptTokens = (toolPromptTokens ?? 0) + count }
            if let count = (usage["completion_tokens"] as? NSNumber)?.intValue { toolCompletionTokens = (toolCompletionTokens ?? 0) + count }
        }
    }

    func finish(error: String? = nil, interrupted: Bool = false) {
        let entry: ChatLog? = lock.withLock {
            guard !done else { return nil }
            done = true
            var entry = log
            entry.durationMs = Int(Date().timeIntervalSince(started) * 1000)
            if retainContent { parse(into: &entry) }
            if !metricsSSE { observeUsage(metricsBody) }
            else if !metricsBody.isEmpty {
                let line = String(decoding: metricsBody, as: UTF8.self)
                if line.hasPrefix("data:") { observeUsage(Data(line.dropFirst(5).utf8)) }
            }
            entry.promptTokens = toolPromptTokens ?? observedPromptTokens ?? entry.promptTokens
            entry.completionTokens = toolCompletionTokens ?? observedCompletionTokens ?? entry.completionTokens
            body.removeAll(keepingCapacity: false); metricsBody.removeAll(keepingCapacity: false)
            if let error { entry.status = "error"; entry.error = error }
            else if interrupted { entry.status = "interrupted" }
            else if httpStatus != 200 { entry.status = "error"; entry.error = entry.error ?? "HTTP \(httpStatus)" }
            return entry
        }
        if let entry { try? store.recordChat(entry, capability: usageCapability, retainContent: retainContent) }
    }

    private func parse(into entry: inout ChatLog) {
        func apply(_ json: [String: Any]) {
            if let message = (json["error"] as? [String: Any])?["message"] as? String ?? json["error"] as? String { entry.error = message }
            if let usage = json["usage"] as? [String: Any] {
                entry.promptTokens = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? entry.promptTokens
                entry.completionTokens = (usage["completion_tokens"] as? NSNumber)?.intValue ?? entry.completionTokens
            }
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return }
            if let reason = choice["finish_reason"] as? String { entry.finishReason = reason }
            for part in [choice["delta"], choice["message"]].compactMap({ $0 as? [String: Any] }) {
                entry.response += ChatLog.text(of: part["content"])
                if let thinking = part["reasoning_content"] as? String ?? part["reasoning"] as? String { entry.reasoning += thinking }
            }
        }
        let text = String(decoding: body, as: UTF8.self)
        // Judge by the body, not the request: tool chats answer a streaming request with one JSON reply.
        if text.hasPrefix("data:") || text.contains("\ndata:") {
            for line in text.split(separator: "\n") where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload != "[DONE]", let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] { apply(json) }
            }
        } else if let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            apply(json)
        }
    }

    /// Drops inline image data and caps very long strings so logs stay small.
    static func redacted(_ value: Any?) -> Any {
        switch value {
        case let string as String:
            if string.hasPrefix("data:") { return "[image]" }
            return string.count > 100_000 ? String(string.prefix(100_000)) + "…" : string
        case let array as [Any]: return array.map { redacted($0) }
        case let object as [String: Any]: return object.mapValues { redacted($0) }
        case let value?: return value
        default: return NSNull()
        }
    }
}

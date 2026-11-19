import Foundation
import GRDB

/// Operational metadata only: deliberately has no prompt, response, reasoning,
/// arguments, file contents or error-message fields.
public struct UsageEvent: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "usage_event"
    public let id: String
    public let deviceID: String
    public let deviceName: String
    public let capability: String
    public let model: String
    public let isWorkflow: Bool
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let durationMs: Int?
    public let status: String
    public let createdAt: Date

    init(log: ChatLog, capability: String = "chat") {
        id = log.id; deviceID = log.deviceID; deviceName = log.deviceName
        self.capability = capability; model = log.model; isWorkflow = false
        promptTokens = log.promptTokens; completionTokens = log.completionTokens
        durationMs = log.durationMs; status = log.status; createdAt = log.createdAt
    }

    init(job: HubJob) {
        id = job.id; deviceID = job.deviceID; deviceName = job.deviceName
        capability = job.capability.rawValue; model = job.model; isWorkflow = true
        promptTokens = nil; completionTokens = nil
        durationMs = job.status.isFinished ? job.duration.map { max(0, Int($0 * 1000)) } : nil
        status = job.status.rawValue; createdAt = job.createdAt
    }
}

func registerUsageMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v8-independent-usage") { db in
        try db.create(table: "usage_event") { t in
            t.primaryKey("id", .text)
            t.column("deviceID", .text).notNull().indexed()
            t.column("deviceName", .text).notNull()
            t.column("capability", .text).notNull()
            t.column("model", .text).notNull()
            t.column("isWorkflow", .boolean).notNull()
            t.column("promptTokens", .integer)
            t.column("completionTokens", .integer)
            t.column("durationMs", .integer)
            t.column("status", .text).notNull()
            t.column("createdAt", .datetime).notNull().indexed()
        }
        try db.execute(sql: """
            INSERT INTO usage_event (id, deviceID, deviceName, capability, model, isWorkflow, promptTokens, completionTokens, durationMs, status, createdAt)
            SELECT id, deviceID, deviceName, 'chat', model, 0, promptTokens, completionTokens, durationMs, status, createdAt FROM chatlog;
            INSERT OR IGNORE INTO usage_event (id, deviceID, deviceName, capability, model, isWorkflow, durationMs, status, createdAt)
            SELECT id, deviceID, deviceName, capability, model, 1,
              CASE WHEN finishedAt IS NOT NULL THEN MAX(0, CAST((julianday(finishedAt)-julianday(COALESCE(startedAt,createdAt)))*86400000 AS INTEGER)) END,
              status, createdAt FROM job;
            """)
    }
}

extension HubStore {
    func recordChat(_ log: ChatLog, capability: String = "chat", retainContent: Bool) throws {
        try database.write { db in
            try UsageEvent(log: log, capability: capability).save(db)
            if retainContent { try log.insert(db) }
        }
    }

    @discardableResult
    public func purgeUsage(olderThan date: Date) throws -> Int {
        try database.write { try UsageEvent.filter(Column("createdAt") < date).deleteAll($0) }
    }

    public func clearUsage() throws {
        _ = try database.write { try UsageEvent.deleteAll($0) }
    }
}

import Foundation
import GRDB

extension PairedDevice: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "device"
}

extension ProviderConfiguration: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "integration"
}

extension WorkflowTemplate: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "template"
}

extension HubFile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "file"
}

extension HubJob: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "job"
}

/// `hub.sqlite`: devices, integrations and settings. Later phases add jobs,
/// files and chat logs as new migrations.
public final class HubStore: Sendable {
    let database: DatabaseQueue

    /// `nil` opens an in-memory database (tests).
    public init(path: String?) throws {
        database = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        if let path { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        try Self.migrator.migrate(database)
    }

    /// Opens `<directory>/hub.sqlite`, importing a CLI-era `paired-devices.json` once.
    public static func open(directory: URL) throws -> HubStore {
        let store = try HubStore(path: directory.appendingPathComponent("hub.sqlite").path)
        let legacy = directory.appendingPathComponent("paired-devices.json")
        if FileManager.default.fileExists(atPath: legacy.path), try store.devices().isEmpty {
            struct LegacyDevice: Decodable { let id, name, app, tokenHash: String; let createdAt: Date; let scopes: [String] }
            let imported = try JSONDecoder().decode([LegacyDevice].self, from: Data(contentsOf: legacy))
            let kinds = Dictionary(uniqueKeysWithValues: try store.integrations().map { ($0.id, $0.kind) })
            for device in imported {
                try store.save(PairedDevice(id: device.id, name: device.name, app: device.app, tokenHash: device.tokenHash,
                    createdAt: device.createdAt, scopes: capabilityScopes(device.scopes, kinds: kinds)))
            }
            try FileManager.default.moveItem(at: legacy, to: legacy.appendingPathExtension("migrated"))
        }
        return store
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("app", .text).notNull()
                t.column("tokenHash", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime)
                t.column("scopes", .text).notNull()
                t.column("logging", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "integration") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("baseURL", .text).notNull()
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            for integration in ProviderConfiguration.defaults { try integration.insert(db) }
        }
        migrator.registerMigration("v2-capabilities") { db in
            try db.create(table: "template") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("integrationID", .text).notNull()
                t.column("capability", .text).notNull()
                t.column("workflow", .text).notNull()
                t.column("slots", .text).notNull()
                t.column("outputNode", .text)
            }
            try db.create(table: "file") { t in
                t.primaryKey("id", .text)
                t.column("deviceID", .text).indexed()
                t.column("filename", .text).notNull()
                t.column("mime", .text).notNull()
                t.column("bytes", .integer).notNull()
                t.column("purpose", .text).notNull()
                t.column("source", .text).notNull()
                t.column("jobID", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.column("deviceID", .text).notNull().indexed()
                t.column("deviceName", .text).notNull()
                t.column("capability", .text).notNull()
                t.column("model", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("status", .text).notNull()
                t.column("progress", .double)
                t.column("error", .text)
                t.column("outputFileIDs", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
            }
            // Phase 1 scopes were integration ids; they become the capabilities those integrations provide.
            let kinds = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, kind FROM integration").map {
                (($0["id"] as String), ProviderKind(rawValue: $0["kind"]) ?? .openai)
            })
            for device in try PairedDevice.fetchAll(db) {
                var copy = device
                copy.scopes = capabilityScopes(device.scopes, kinds: kinds)
                try copy.update(db)
            }
        }
        registerChatLogMigration(&migrator)
        migrator.registerMigration("v4-long-jobs") { db in
            try db.alter(table: "job") { t in
                t.add(column: "startedAt", .datetime)
                t.add(column: "promptID", .text)
                t.add(column: "integrationID", .text)
                t.add(column: "templateID", .text)
                t.add(column: "queuePosition", .integer)
                t.add(column: "currentNode", .text)
                t.add(column: "etaSeconds", .integer)
                t.add(column: "waitingReason", .text)
                t.add(column: "previewUpdatedAt", .datetime)
            }
            try db.alter(table: "template") { t in t.add(column: "timeoutMinutes", .integer) }
        }
        migrator.registerMigration("v5-job-error-code") { db in
            try db.alter(table: "job") { t in t.add(column: "errorCode", .text) }
        }
        migrator.registerMigration("v6-job-recipes") { db in
            try db.alter(table: "job") { t in t.add(column: "recipe", .text) }
        }
        migrator.registerMigration("v7-device-profiles") { db in
            try db.alter(table: "device") { t in
                t.add(column: "profileID", .text)
                t.add(column: "fileQuotaBytes", .integer)
                t.add(column: "maxJobs", .integer)
                t.add(column: "workProfileID", .text)
            }
        }
        registerUsageMigration(&migrator)
        migrator.registerMigration("v9-smart-queue") { db in
            try db.alter(table: "job") { t in
                t.add(column: "priority", .integer)
                t.add(column: "schedule", .text)
                t.add(column: "dispatchedAt", .datetime)
            }
        }
        return migrator
    }

    // MARK: Devices

    public func devices() throws -> [PairedDevice] {
        try database.read { try PairedDevice.order(Column("createdAt")).fetchAll($0) }
    }

    public func save(_ device: PairedDevice) throws {
        try database.write { try device.save($0) }
    }

    public func deleteDevice(_ id: String) throws {
        _ = try database.write { try PairedDevice.deleteOne($0, key: id) }
    }

    // MARK: Integrations

    public func integrations() throws -> [ProviderConfiguration] {
        try database.read { try ProviderConfiguration.order(Column.rowID).fetchAll($0) }
    }

    public func save(_ integration: ProviderConfiguration) throws {
        try integration.validate()
        try database.write { try integration.save($0) }
    }

    public func deleteIntegration(_ id: String) throws {
        _ = try database.write { try ProviderConfiguration.deleteOne($0, key: id) }
    }

    // MARK: Templates

    public func templates() throws -> [WorkflowTemplate] {
        try database.read { try WorkflowTemplate.order(Column("name")).fetchAll($0) }
    }

    public func save(_ template: WorkflowTemplate) throws {
        try template.validate()
        try database.write { try template.save($0) }
    }

    public func deleteTemplate(_ id: String) throws {
        _ = try database.write { try WorkflowTemplate.deleteOne($0, key: id) }
    }

    // MARK: Files and jobs

    public func files(deviceID: String?) throws -> [HubFile] {
        try database.read { db in
            var query = HubFile.order(Column("createdAt").desc)
            if let deviceID { query = query.filter(Column("deviceID") == deviceID) }
            return try query.fetchAll(db)
        }
    }

    public func file(_ id: String) throws -> HubFile? {
        try database.read { try HubFile.fetchOne($0, key: id) }
    }

    public func usage(deviceID: String) throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(bytes), 0) FROM file WHERE deviceID = ?", arguments: [deviceID]) ?? 0 }
    }

    public func save(_ file: HubFile) throws {
        try database.write { try file.save($0) }
    }

    public func deleteFile(_ id: String) throws {
        _ = try database.write { try HubFile.deleteOne($0, key: id) }
    }

    public func jobs(deviceID: String?, limit: Int = 100) throws -> [HubJob] {
        try database.read { db in
            var query = HubJob.order(Column("createdAt").desc).limit(limit)
            if let deviceID { query = query.filter(Column("deviceID") == deviceID) }
            return try query.fetchAll(db)
        }
    }

    public func unfinishedJobs() throws -> [HubJob] {
        try database.read { db in
            try HubJob.filter([JobStatus.queued.rawValue, JobStatus.inProgress.rawValue].contains(Column("status")))
                .order(Column("createdAt")).fetchAll(db)
        }
    }

    public func save(_ job: HubJob) throws {
        try database.write { db in
            try job.save(db)
            try UsageEvent(job: job).save(db)
        }
    }

    public func deleteJob(_ id: String) throws {
        _ = try database.write { try HubJob.deleteOne($0, key: id) }
    }

    public func job(_ id: String) throws -> HubJob? {
        try database.read { try HubJob.fetchOne($0, key: id) }
    }

    /// Mean execution time (seconds) of the last ten completed runs of a model, for ETAs.
    public func averageDuration(model: String) throws -> TimeInterval? {
        try database.read { db in
            try Double.fetchOne(db, sql: """
                SELECT AVG((julianday(finishedAt) - julianday(startedAt)) * 86400) FROM (
                  SELECT startedAt, finishedAt FROM job WHERE model = ? AND status = 'completed' AND startedAt IS NOT NULL
                  ORDER BY createdAt DESC LIMIT 10)
                """, arguments: [model])
        }
    }

    // MARK: Settings

    public func settings() throws -> HubSettings {
        try database.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'hub'") else { return HubSettings() }
            return try JSONDecoder().decode(HubSettings.self, from: Data(json.utf8))
        }
    }

    public func save(_ settings: HubSettings) throws {
        try settings.validate()
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try database.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('hub', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [json])
        }
    }
}

/// Phase 1 scopes were integration ids; each becomes the capabilities that integration provides.
func capabilityScopes(_ scopes: [String], kinds: [String: ProviderKind]) -> [String] {
    var result: [String] = []
    for scope in scopes {
        // Frozen at what each kind offered when scopes became capabilities (v2): new
        // capabilities added later are never granted silently by a migration.
        let v2: [ProviderKind: [String]] = [.openai: ["chat"], .comfyui: ["image.create", "image.edit"]]
        let mapped = scope.hasPrefix("mcp:") || Capability(rawValue: scope) != nil
            ? [scope] : (kinds[scope].flatMap { v2[$0] } ?? [])
        for item in mapped where !result.contains(item) { result.append(item) }
    }
    return result
}

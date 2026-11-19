import Foundation
import GRDB

/// Content-independent request metadata for the Usage screen.
public struct UsageReport: Sendable, Equatable {
    public struct Day: Sendable, Equatable, Identifiable {
        public let day: Date
        public let capability: String
        public let count: Int
        public var id: String { "\(day.timeIntervalSince1970)-\(capability)" }
    }
    public struct Device: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let chats: Int
        public let promptTokens: Int
        public let completionTokens: Int
        public let jobs: Int
        public let failedJobs: Int
        public let requests: Int
    }
    public struct Model: Sendable, Equatable, Identifiable {
        public let id: String
        public let runs: Int
        public let failures: Int
        /// Mean seconds per completed run (jobs) or per reply (chat).
        public let averageSeconds: Double?
        public let isWorkflow: Bool
    }
    public let days: [Day]
    public let devices: [Device]
    public let models: [Model]
    public let unreportedTokenRequests: Int
    public var totalRequests: Int { days.reduce(0) { $0 + $1.count } }
}

extension HubStore {
    public func usage(since: Date) throws -> UsageReport {
        try database.read { db in
            let dayRows = try Row.fetchAll(db, sql: """
                SELECT date(createdAt, 'localtime') AS day, capability, COUNT(*) AS n
                FROM usage_event WHERE createdAt >= ? GROUP BY day, capability ORDER BY day
                """, arguments: [since])
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy-MM-dd"; parser.timeZone = .current
            let days = dayRows.compactMap { row -> UsageReport.Day? in
                guard let text: String = row["day"], let day = parser.date(from: text) else { return nil }
                return .init(day: day, capability: row["capability"], count: row["n"])
            }
            let deviceRows = try Row.fetchAll(db, sql: """
                SELECT deviceID AS id, MAX(deviceName) AS name, COUNT(*) AS requests,
                  SUM(CASE WHEN capability='chat' THEN 1 ELSE 0 END) AS chats,
                  SUM(COALESCE(promptTokens,0)) AS pin, SUM(COALESCE(completionTokens,0)) AS pout,
                  SUM(isWorkflow) AS jobs, SUM(CASE WHEN isWorkflow=1 AND status='failed' THEN 1 ELSE 0 END) AS failed
                FROM usage_event WHERE createdAt >= ? GROUP BY deviceID ORDER BY requests DESC
                """, arguments: [since])
            let devices = deviceRows.map { row in
                UsageReport.Device(id: row["id"], name: row["name"], chats: row["chats"], promptTokens: row["pin"],
                    completionTokens: row["pout"], jobs: row["jobs"], failedJobs: row["failed"], requests: row["requests"])
            }
            let modelRows = try Row.fetchAll(db, sql: """
                SELECT model, MAX(isWorkflow) AS workflow, COUNT(*) AS runs,
                  SUM(CASE WHEN status IN ('failed','error') THEN 1 ELSE 0 END) AS failures,
                  AVG(CASE WHEN status='completed' THEN durationMs END)/1000.0 AS seconds
                FROM usage_event WHERE createdAt >= ? GROUP BY model ORDER BY runs DESC
                """, arguments: [since])
            let models = modelRows.map { row in
                UsageReport.Model(id: row["model"], runs: row["runs"], failures: row["failures"], averageSeconds: row["seconds"],
                    isWorkflow: (row["workflow"] as Int) == 1)
            }
            let unreported = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM usage_event WHERE createdAt >= ? AND status='completed' AND
                ((capability='chat' AND (promptTokens IS NULL OR completionTokens IS NULL))
                  OR (capability='embeddings' AND promptTokens IS NULL))
                """, arguments: [since]) ?? 0
            return UsageReport(days: days, devices: devices, models: models, unreportedTokenRequests: unreported)
        }
    }
}

extension PairingAuthority {
    public static let playgroundApp = "localhub-playground"

    /// A fresh token for the app's own Playground: an internal device with the given scopes, replacing
    /// the previous one. Lives only in memory; nothing outside this process ever sees it.
    public func issuePlaygroundToken(scopes: [String]) throws -> (token: String, deviceID: String) {
        for device in listDevices() where device.app == Self.playgroundApp { try revoke(device.id) }
        return try issue(name: "Playground (this Mac)", app: Self.playgroundApp, scopes: scopes)
    }
}

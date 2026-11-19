import Foundation
import GRDB
import XCTest
@testable import LocalHubCore

final class RecipeMigrationTests: XCTestCase {
    func testPreRecipeDatabaseMigratesWithoutChangingExistingJobsOrIntegrations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hub.sqlite").path
        let old = try DatabaseQueue(path: path)
        try HubStore.migrator.migrate(old, upTo: "v5-job-error-code")
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO job (id, deviceID, deviceName, capability, model, prompt, status, outputFileIDs, createdAt)
                VALUES ('legacy-job', 'legacy-device', 'Old Tablet', 'image.create', 'comfyui/sdxl', 'old prompt', 'completed', '[]', '2026-11-18 12:00:00.000')
                """)
        }
        let upgraded = try HubStore(path: path)
        let job = try XCTUnwrap(upgraded.job("legacy-job"))
        XCTAssertEqual(job.prompt, "old prompt")
        XCTAssertEqual(job.status, .completed)
        XCTAssertNil(job.recipe)
        XCTAssertEqual(try upgraded.integrations().count, ProviderConfiguration.defaults.count)
    }
}

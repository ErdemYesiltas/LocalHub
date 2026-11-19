import Foundation
import GRDB
import XCTest
@testable import LocalHubCore

final class UsageMetadataTests: XCTestCase {
    private func device(logging: Bool) -> PairedDevice {
        PairedDevice(id: "pad", name: "Pad", app: "tests", tokenHash: "hash", createdAt: Date(), scopes: ["chat"], logging: logging)
    }

    private func response(_ content: String = "private-reply") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]], "usage": ["prompt_tokens": 11, "completion_tokens": 7]])
    }

    func testLoggingOffRecordsOnlyMetadataAndKeepsTokens() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HubStore.open(directory: directory)
        let recorder = ChatRecorder(store: store, device: device(logging: false), model: "ai/model", integrationID: "ai",
            request: ["messages": [["role": "user", "content": "unique-secret-prompt-71041"]]])
        recorder.received(status: 200); recorder.append(try response("unique-secret-reply-93217")); recorder.finish(); recorder.finish()
        XCTAssertTrue(try store.chatLogs().isEmpty)
        let usage = try store.usage(since: .distantPast)
        XCTAssertEqual(usage.totalRequests, 1); XCTAssertEqual(usage.devices.first?.promptTokens, 11)
        XCTAssertEqual(usage.devices.first?.completionTokens, 7); XCTAssertEqual(usage.unreportedTokenRequests, 0)
        let columns = try store.database.read { try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('usage_event')") }
        for column in ["prompt", "response", "reasoning", "messages", "error", "arguments"] { XCTAssertFalse(columns.contains(column)) }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("hub.sqlite") {
            let data = try Data(contentsOf: url)
            XCTAssertNil(data.range(of: Data("unique-secret-prompt-71041".utf8)))
            XCTAssertNil(data.range(of: Data("unique-secret-reply-93217".utf8)))
        }
    }

    func testLateStreamingUsageIsCountedBeyondTheContentCaptureLimit() throws {
        let store = try HubStore(path: nil)
        let recorder = ChatRecorder(store: store, device: device(logging: false), model: "ai/model", integrationID: "ai", request: ["stream": true])
        recorder.received(status: 200, streaming: true)
        let content = String(repeating: "x", count: 32_768)
        let chunk = Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n\n".utf8)
        for _ in 0..<100 { recorder.append(chunk) }
        let tail = Data("data: {\"usage\":{\"prompt_tokens\":29,\"completion_tokens\":31},\"choices\":[]}\n\ndata: [DONE]\n\n".utf8)
        recorder.append(Data(tail.prefix(7))); recorder.append(Data(tail.dropFirst(7))); recorder.finish(interrupted: true)
        let usage = try store.usage(since: .distantPast)
        XCTAssertEqual(usage.devices.first?.promptTokens, 29); XCTAssertEqual(usage.devices.first?.completionTokens, 31)
        XCTAssertEqual(usage.totalRequests, 1); XCTAssertTrue(try store.chatLogs().isEmpty)
        let row = try store.database.read { try Row.fetchOne($0, sql: "SELECT status FROM usage_event") }
        XCTAssertEqual(row?["status"] as String?, "interrupted")
    }

    func testToolRoundTotalsAreNotDoubleCountedByTheFinalReply() throws {
        let store = try HubStore(path: nil)
        let recorder = ChatRecorder(store: store, device: device(logging: false), model: "ai/model", integrationID: "ai", request: [:])
        recorder.recordToolUsage(["usage": ["prompt_tokens": 5, "completion_tokens": 2]])
        recorder.recordToolUsage(["usage": ["prompt_tokens": 11, "completion_tokens": 7]])
        recorder.received(status: 200); recorder.append(try response()); recorder.finish()
        let usage = try store.usage(since: .distantPast)
        XCTAssertEqual(usage.devices.first?.promptTokens, 16); XCTAssertEqual(usage.devices.first?.completionTokens, 9)
    }

    func testDeletingContentDoesNotDeleteUsageAndClearingUsageDoesNotDeleteContent() throws {
        let store = try HubStore(path: nil)
        let recorder = ChatRecorder(store: store, device: device(logging: true), model: "ai/model", integrationID: "ai",
            request: ["messages": [["role": "user", "content": "a prompt"]]])
        recorder.received(status: 200); recorder.append(try response()); recorder.finish()
        XCTAssertEqual(try store.chatLogs().count, 1)
        try store.clearUsage(); XCTAssertEqual(try store.chatLogs().count, 1)
        XCTAssertEqual(try store.usage(since: .distantPast).totalRequests, 0)
        let another = ChatRecorder(store: store, device: device(logging: true), model: "ai/model", integrationID: "ai", request: [:])
        another.received(status: 200); another.append(try response()); another.finish()
        _ = try store.purgeChatLogs(olderThan: Date().addingTimeInterval(1))
        XCTAssertTrue(try store.chatLogs().isEmpty)
        XCTAssertEqual(try store.usage(since: .distantPast).totalRequests, 1)
    }

    func testNonChatMetadataHasNoChatLogAndReportsMissingTokens() throws {
        let store = try HubStore(path: nil)
        let recorder = ChatRecorder(store: store, device: device(logging: true), model: "ai/embed", integrationID: "ai", request: [:], capability: "embeddings")
        recorder.received(status: 200); recorder.append(Data(#"{"data":[{"embedding":[0.1]}]}"#.utf8)); recorder.finish()
        let usage = try store.usage(since: .distantPast)
        XCTAssertEqual(usage.totalRequests, 1); XCTAssertEqual(usage.unreportedTokenRequests, 1)
        XCTAssertEqual(usage.days.first?.capability, "embeddings"); XCTAssertTrue(try store.chatLogs().isEmpty)
    }

    func testMigrationBackfillsOnceAndJobDeletionPreservesMetadata() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hub.sqlite").path, old = try DatabaseQueue(path: directory.appendingPathComponent("hub.sqlite").path)
        try HubStore.migrator.migrate(old, upTo: "v7-device-profiles")
        let log = ChatLog(id: "old-chat", deviceID: "pad", deviceName: "Pad", app: "tests", model: "ai/model", integrationID: "ai",
            messages: "[]", prompt: "private", response: "private", finishReason: nil, promptTokens: 4, completionTokens: 5,
            durationMs: 1000, status: "completed", error: nil, stream: false, createdAt: Date())
        let job = HubJob(id: "old-job", deviceID: "pad", deviceName: "Pad", capability: .imageCreate, model: "comfy/model", prompt: "private",
            status: .completed, progress: 1, error: nil, outputFileIDs: [], createdAt: Date().addingTimeInterval(-2), finishedAt: Date())
        try old.write { db in
            try log.insert(db)
            // A historical schema must use its historical columns, rather than
            // today's Codable record (which includes future queue columns).
            try db.execute(sql: """
                INSERT INTO job (id, deviceID, deviceName, capability, model, prompt, status, outputFileIDs, createdAt, finishedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [job.id, job.deviceID, job.deviceName, job.capability.rawValue, job.model, job.prompt,
                                  job.status.rawValue, "[]", job.createdAt, job.finishedAt])
        }
        let store = try HubStore(path: path)
        XCTAssertEqual(try store.usage(since: .distantPast).totalRequests, 2)
        try store.deleteChatLog(log.id); try store.deleteJob(job.id)
        XCTAssertEqual(try store.usage(since: .distantPast).totalRequests, 2)
        let again = try HubStore(path: path)
        XCTAssertEqual(try again.usage(since: .distantPast).totalRequests, 2)
        XCTAssertEqual(try again.purgeUsage(olderThan: Date().addingTimeInterval(1)), 2)
        XCTAssertEqual(try again.usage(since: .distantPast).totalRequests, 0)
    }
}
